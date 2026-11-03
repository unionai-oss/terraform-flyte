# Exposure modes (exposure.tf): the front door for each mode the infra root settles. Plans against mock providers and
# fixtures of the infra root's outputs; nothing is created.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a public deployment (infra's contract.tftest.hcl keeps the fixture equal to them).
# Null outputs are left out, as Terraform leaves them out of state.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
  }
}

run "public" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = local.public && local.oauth && local.traefik
    error_message = "public implies OAuth and Traefik"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).service.spec.type == "LoadBalancer"
    error_message = "Traefik is a LoadBalancer Service in public mode"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).service.annotations == { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" }
    error_message = "the load balancer is a Network Load Balancer"
  }

  assert {
    condition     = length(helm_release.cert_manager) == 1
    error_message = "cert-manager is installed in public mode"
  }

  assert {
    condition     = helm_release.cert_manager[0].version == "v1.21.3" && helm_release.traefik[0].version == "42.2.0"
    error_message = "chart pins"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.identityHeaders.subjectHeader == "X-Auth-Request-User"
    error_message = "behind oauth2-proxy the subject header is X-Auth-Request-User"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.identityHeaders.emailHeader == "X-Auth-Request-Email"
    error_message = "behind oauth2-proxy the email header is X-Auth-Request-Email"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte[0].metadata[0].annotations["cert-manager.io/cluster-issuer"] == "letsencrypt"
    error_message = "cert-manager issues the certificate"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte[0].metadata[0].annotations["traefik.ingress.kubernetes.io/router.middlewares"] == "traefik-strip-identity@kubernetescrd,traefik-oauth@kubernetescrd,traefik-root-redirect@kubernetescrd"
    error_message = "identity headers are stripped, then OAuth is enforced, then / goes to the console"
  }

  assert {
    condition     = one(kubernetes_ingress_v1.flyte[0].spec[0].rule).host == "flyte.example.com" && kubernetes_ingress_v1.flyte[0].spec[0].ingress_class_name == "traefik"
    error_message = "the ingress serves the public hostname on Traefik"
  }

  assert {
    condition     = one([for p in one(one(kubernetes_ingress_v1.flyte[0].spec[0].rule).http).path : p if p.path == "/"]).backend[0].service[0].name == "flyte-http"
    error_message = "/ goes to the Flyte API"
  }

  assert {
    condition     = one([for p in one(one(kubernetes_ingress_v1.flyte[0].spec[0].rule).http).path : p if p.path == "/v2"]).backend[0].service[0].name == "flyte-console"
    error_message = "/v2 goes to the console"
  }

  assert {
    condition = (
      [for o in yamldecode(helm_release.traefik[0].values[0]).extraObjects : o.metadata.name] ==
      ["strip-identity", "oauth", "root-redirect", "letsencrypt"]
    )
    error_message = "Traefik carries the three middlewares and the ClusterIssuer"
  }

  assert {
    condition = (
      yamldecode(helm_release.traefik[0].values[0]).extraObjects[0].spec.headers.customRequestHeaders == {
        "X-Auth-Request-User"               = ""
        "X-Auth-Request-Email"              = ""
        "X-Auth-Request-Preferred-Username" = ""
        "X-Auth-Request-Groups"             = ""
      }
    )
    error_message = "strip-identity sets every X-Auth-Request-* header to empty, so a client cannot assert an identity"
  }

  assert {
    condition = (
      yamldecode(helm_release.traefik[0].values[0]).extraObjects[1].spec.forwardAuth.authResponseHeaders ==
      ["X-Auth-Request-User", "X-Auth-Request-Email", "X-Auth-Request-Preferred-Username", "X-Auth-Request-Groups"]
    )
    error_message = "forward-auth copies the identity headers from the oauth2-proxy response"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).extraObjects[1].spec.forwardAuth.address == "http://oauth2-proxy.oauth2-proxy.svc.cluster.local/" && yamldecode(helm_release.traefik[0].values[0]).extraObjects[1].spec.forwardAuth.trustForwardHeader
    error_message = "forward-auth goes to the oauth2-proxy root (which redirects browsers), not /oauth2/auth (a bare 401)"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.replacement == "https://flyte.example.com/v2"
    error_message = "the root path redirects to the console on the public https URL"
  }

  # Terraform's replace() with a /regex/ is Go's regexp ReplaceAllString, the call Traefik's redirectRegex makes on the
  # URL it rebuilds from the request.
  assert {
    condition = alltrue([
      for url in ["https://flyte.example.com/", "https://flyte.example.com", "http://flyte.example.com/"] :
      replace(url, "/${yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.regex}/", yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.replacement) == "https://flyte.example.com/v2"
    ])
    error_message = "a request for the bare root is sent to https://<host>/v2"
  }

  assert {
    condition = alltrue([
      for url in ["https://flyte.example.com/v2", "https://flyte.example.com/v2/", "https://flyte.example.com/flyteidl2.task.TaskService/ListTasks", "https://flyte.example.com/?next=x"] :
      !can(regex(yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.regex, url))
    ])
    error_message = "only the bare root is redirected"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).extraObjects[3].spec.acme.email == "admin@example.com"
    error_message = "the ACME contact is public.acme_email"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).ports.web.http.redirections.entryPoint == { to = "websecure", scheme = "https", permanent = true }
    error_message = "public mode redirects HTTP to HTTPS"
  }

  assert {
    condition     = time_sleep.traefik_destroy[0].destroy_duration == "120s"
    error_message = "the load balancer gets time to go before the VPC is deleted"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte_discovery[0].metadata[0].annotations["traefik.ingress.kubernetes.io/router.middlewares"] == "traefik-strip-identity@kubernetescrd"
    error_message = "the discovery Ingress bypasses forward-auth but still strips identity headers"
  }

  assert {
    condition = (
      toset([for p in one(one(kubernetes_ingress_v1.flyte_discovery[0].spec[0].rule).http).path : p.path]) ==
      toset(["/.well-known/oauth-authorization-server", "/flyteidl2.auth.AuthMetadataService"]) &&
      alltrue([for p in one(one(kubernetes_ingress_v1.flyte_discovery[0].spec[0].rule).http).path : p.backend[0].service[0].name == "flyte-http"])
    )
    error_message = "only the unauthenticated discovery paths, straight to the Flyte API"
  }
}

run "tailnet_traefik_has_no_redirect_or_sleep" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale-oauth.json")) : k => v if v != null }
    }
  }

  variables {
    tailscale_oauth_client_secret = join("", ["placeholder"])
  }

  assert {
    condition     = length(time_sleep.traefik_destroy) == 0 && yamldecode(helm_release.traefik[0].values[0]).ports.web.http.redirections.entryPoint == {}
    error_message = "no LoadBalancer, so no destroy pause and no HTTP redirect (Tailscale terminates TLS)"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).service.spec.type == "ClusterIP" && yamldecode(helm_release.traefik[0].values[0]).service.annotations == {}
    error_message = "on the tailnet Traefik is internal and asks for no load balancer"
  }

  # The Tailscale Ingress talks plain HTTP to Traefik, so Traefik sees http://<host>/ for a browser's https request.
  assert {
    condition = (
      local.infra.flyte_url == "https://flyte.${local.infra.tailnet_domain}" &&
      yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.replacement == "${local.infra.flyte_url}/v2" &&
      replace(
        "http://${trimprefix(local.infra.flyte_url, "https://")}/",
        "/${yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.regex}/",
        yamldecode(helm_release.traefik[0].values[0]).extraObjects[2].spec.redirectRegex.replacement,
      ) == "${local.infra.flyte_url}/v2"
    )
    error_message = "on the tailnet the bare root redirects to the https tailnet URL, not to http://"
  }
}
