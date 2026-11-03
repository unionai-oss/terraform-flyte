# How the Flyte endpoint is reached (CONVENTIONS section 6): the front door. The Kubernetes text is shared with
# the AWS root; what is Azure-specific is the load balancer annotations (flyte.tf) and the wait after Traefik's
# destroy for AKS to delete its load balancer.

locals {
  # The mode, resolved in the infra root (its exposure.tf), which also builds the URL.
  public = local.infra.exposure == "public"
  oauth  = local.infra.oauth_enabled

  # Traefik is the front door whenever OAuth is on or the endpoint is public.
  traefik = local.oauth || local.public

  # Flyte attributes runs to the identity the front door vouches for (CONVENTIONS section 7).
  identity_headers = local.oauth ? {
    claimsJwtHeader = ""
    subjectHeader   = "X-Auth-Request-User"
    emailHeader     = "X-Auth-Request-Email"
    } : {
    claimsJwtHeader = ""
    subjectHeader   = "Tailscale-User-Login"
    emailHeader     = "Tailscale-User-Login"
  }

  # Headers oauth2-proxy sets after authenticating; Traefik clears them from client requests first and copies them
  # from the oauth2-proxy response, so a client cannot assert an identity itself.
  auth_headers = ["X-Auth-Request-User", "X-Auth-Request-Email", "X-Auth-Request-Preferred-Username", "X-Auth-Request-Groups"]

  # Applied to every Ingress that goes through Traefik with OAuth.
  oauth_middlewares = "traefik-strip-identity@kubernetescrd,traefik-oauth@kubernetescrd"

  # Paths that serve API clients (SDK, CLI, MCP clients) rather than browsers: oauth2-proxy answers an
  # unauthenticated request to them with 401 instead of a redirect to sign-in. Regular expressions, no commas.
  api_route_regexes = ["^/flyteidl2\\.", "^${local.mcp_path}"]
}

# Traefik's LoadBalancer Service owns an Azure load balancer and public IP in the cluster's node resource group, and
# AKS' cloud controller deletes them after Helm returns. Traefik depends on this resource, so a destroy removes
# Traefik first and then waits out destroy_duration here: the pause that lets the controller finish before
# `terraform -chdir=infra destroy` removes the cluster and the network.
resource "time_sleep" "traefik_destroy" {
  # Only the public mode creates a LoadBalancer Service.
  count = local.public ? 1 : 0

  destroy_duration = "120s"
}

# Public mode only: Let's Encrypt certificates for the Traefik ingress.
resource "helm_release" "cert_manager" {
  # Only the public mode terminates TLS itself; on the tailnet Tailscale provides the certificate.
  count = local.public ? 1 : 0

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.21.3"

  values = [yamlencode({
    crds = { enabled = true }
  })]
}

resource "helm_release" "traefik" {
  # The front door whenever OAuth is on or the mode is public.
  count = local.traefik ? 1 : 0

  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "42.2.0"

  # Custom resources go in extraObjects (not kubernetes_manifest) because kubernetes_manifest needs the CRDs at
  # plan time, before this release has installed them.
  values = [yamlencode({
    service = {
      annotations = local.public ? local.load_balancer_annotations : {}
      spec        = { type = local.public ? "LoadBalancer" : "ClusterIP" }
    }
    # Public mode listens on plain HTTP only to send browsers (and the ACME challenge, which follows redirects) to
    # HTTPS. On the tailnet Tailscale terminates TLS and talks plain HTTP to Traefik, so no redirect there.
    ports = {
      web = {
        http = {
          redirections = {
            # A for expression, not a conditional: a conditional would unify both branches to map(string) and turn
            # permanent into the string "true", which the chart's schema rejects.
            entryPoint = { for k, v in { to = "websecure", scheme = "https", permanent = true } : k => v if local.public }
          }
        }
      }
    }
    extraObjects = concat(
      [
        {
          apiVersion = "traefik.io/v1alpha1"
          kind       = "Middleware"
          metadata   = { name = "strip-identity" }
          spec = {
            # An empty value removes the header from the request.
            headers = { customRequestHeaders = { for h in local.auth_headers : h => "" } }
          }
        },
        {
          apiVersion = "traefik.io/v1alpha1"
          kind       = "Middleware"
          metadata   = { name = "oauth" }
          spec = {
            forwardAuth = {
              # The oauth2-proxy root (upstream static://202), not /oauth2/auth: /oauth2/auth only ever answers 202
              # or 401, so a browser would see a bare 401. At the root oauth2-proxy answers 202 when signed in,
              # redirects a browser to sign-in, and still answers 401 for the api-route paths and JSON clients.
              # Chosen over an errors middleware (the other documented pattern) because it needs no extra
              # middleware, router or status rewrite per Ingress.
              address             = "http://oauth2-proxy.${local.infra.service_accounts.oauth2_proxy.namespace}.svc.cluster.local/"
              authResponseHeaders = local.auth_headers
              trustForwardHeader  = true
            }
          }
        },
        {
          apiVersion = "traefik.io/v1alpha1"
          kind       = "Middleware"
          metadata   = { name = "root-redirect" }
          spec = {
            # Only the bare root: the console lives under /v2 and the API paths never request "/". The target is
            # the configured https URL, not the request's own scheme and host: Traefik builds the URL it matches
            # with the scheme from req.TLS alone, so behind the Tailscale Ingress (which talks plain HTTP to
            # Traefik) a capture-group target such as "${1}/v2" would send the browser to http://.
            redirectRegex = {
              regex       = "^https?://[^/]+/?$"
              replacement = "${local.infra.flyte_url}/v2"
              permanent   = false
            }
          }
        },
      ],
      local.public ? [{
        apiVersion = "cert-manager.io/v1"
        kind       = "ClusterIssuer"
        metadata   = { name = "letsencrypt" }
        spec = {
          acme = {
            server              = "https://acme-v02.api.letsencrypt.org/directory"
            email               = local.infra.public.acme_email
            privateKeySecretRef = { name = "letsencrypt-account-key" }
            solvers             = [{ http01 = { ingress = { ingressClassName = "traefik" } } }]
          }
        }
      }] : [],
    )
  })]

  # The ClusterIssuer in extraObjects needs cert-manager's CRDs and webhook to be ready first.
  # The time_sleep is destroyed after this release (see its comment).
  depends_on = [helm_release.cert_manager, time_sleep.traefik_destroy]
}

# Console (/v2) and API (everything else) behind Traefik. In tailscale mode no host is set: the Tailscale Ingress
# forwards every request to Traefik.
resource "kubernetes_ingress_v1" "flyte" {
  # Only when Traefik is the front door; otherwise Tailscale routes straight to the Services (tailscale.tf).
  count = local.traefik ? 1 : 0

  metadata {
    name      = "flyte"
    namespace = kubernetes_namespace_v1.flyte.metadata[0].name

    annotations = merge(
      local.public ? { "cert-manager.io/cluster-issuer" = "letsencrypt" } : {},
      local.oauth ? { "traefik.ingress.kubernetes.io/router.middlewares" = "${local.oauth_middlewares},traefik-root-redirect@kubernetescrd" } : {},
    )
  }

  spec {
    ingress_class_name = "traefik"

    dynamic "tls" {
      # Public mode only: the certificate cert-manager issues for the hostname.
      for_each = local.public ? [1] : []

      content {
        hosts       = [local.infra.public.hostname]
        secret_name = "flyte-tls"
      }
    }

    rule {
      host = local.public ? local.infra.public.hostname : null

      http {
        path {
          path      = "/v2"
          path_type = "Prefix"

          backend {
            service {
              name = "flyte-console"
              port {
                number = 80
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "flyte-http"
              port {
                number = 8090
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.flyte, helm_release.traefik]
}

# Discovery endpoints the SDK and CLI call before they hold a token (the flyte-binary chart's wellknownIngress
# paths). They must bypass forward-auth, so they get their own Ingress without the OAuth middleware; the identity
# headers are still stripped.
resource "kubernetes_ingress_v1" "flyte_discovery" {
  # Only when OAuth is on; without it nothing asks for a token.
  count = local.oauth ? 1 : 0

  metadata {
    name      = "flyte-discovery"
    namespace = kubernetes_namespace_v1.flyte.metadata[0].name

    # No cert-manager annotation: the main Ingress already requests the flyte-tls certificate for this host.
    annotations = { "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-strip-identity@kubernetescrd" }
  }

  spec {
    ingress_class_name = "traefik"

    dynamic "tls" {
      # Public mode only: the certificate the main Ingress requests.
      for_each = local.public ? [1] : []

      content {
        hosts       = [local.infra.public.hostname]
        secret_name = "flyte-tls"
      }
    }

    rule {
      host = local.public ? local.infra.public.hostname : null

      http {
        dynamic "path" {
          # The paths from the chart's flyte-binary.ingress.wellknownPaths helper (its "/*" entries are the same
          # prefix as the bare service path).
          for_each = ["/.well-known/oauth-authorization-server", "/flyteidl2.auth.AuthMetadataService"]

          content {
            path      = path.value
            path_type = "Prefix"

            backend {
              service {
                name = "flyte-http"
                port {
                  number = 8090
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.flyte, helm_release.traefik]
}

# Public mode only: the address to point your DNS record at.
data "kubernetes_service_v1" "traefik" {
  # Only the public mode has a LoadBalancer Service.
  count = local.public ? 1 : 0

  metadata {
    name      = "traefik"
    namespace = "traefik"
  }

  # Read after the release creates the Service and the cloud assigns the address.
  depends_on = [helm_release.traefik]
}
