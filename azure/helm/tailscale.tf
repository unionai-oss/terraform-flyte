# Add-on: reach Flyte (and the MCP server) from a tailnet through the Tailscale Kubernetes operator. Off by default.

resource "kubernetes_namespace_v1" "tailscale" {
  # Only with the add-on.
  count = local.infra.enable_tailscale ? 1 : 0

  metadata {
    name = "tailscale"
  }
}

resource "helm_release" "tailscale_operator" {
  # Only with the add-on.
  count = local.infra.enable_tailscale ? 1 : 0

  name       = "tailscale-operator"
  namespace  = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  version    = "1.104.2"

  values = [yamlencode({
    oauth = { clientId = local.infra.tailscale.oauth_client_id }
    # The tags the operator gives the proxies it creates (the operator itself keeps its default tag).
    proxyConfig = { defaultTags = join(",", local.infra.tailscale.tags) }
  })]

  set_sensitive = [{
    name  = "oauth.clientSecret"
    value = var.tailscale_oauth_client_secret
  }]
}

# Without OAuth the Tailscale proxy talks to the Flyte Services directly; with OAuth everything goes through
# Traefik, which forward-auths to oauth2-proxy.
resource "kubernetes_ingress_v1" "flyte_tailnet" {
  # Only in tailscale mode (which requires the add-on).
  count = local.infra.enable_tailscale && local.infra.exposure == "tailscale" ? 1 : 0

  metadata {
    name = "flyte-tailnet"
    # An Ingress can only name Services in its own namespace: Traefik's, or Flyte's.
    namespace = local.oauth ? "traefik" : kubernetes_namespace_v1.flyte.metadata[0].name
  }

  spec {
    ingress_class_name = "tailscale"

    tls {
      hosts = [local.infra.tailscale.flyte_hostname]
    }

    rule {
      http {
        dynamic "path" {
          # The console lives under /v2 on its own Service; with OAuth Traefik does this routing instead.
          for_each = local.oauth ? [] : [1]

          content {
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
        }

        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = local.oauth ? "traefik" : "flyte-http"
              port {
                number = local.oauth ? 80 : 8090
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.tailscale_operator, helm_release.flyte, helm_release.traefik]
}
