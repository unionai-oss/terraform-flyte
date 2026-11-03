# Tailscale add-on (tailscale.tf): off unless the infra root turns it on, the tailnet Ingress, and the client secret.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a tailnet deployment without OAuth (infra's contract.tftest.hcl keeps the fixture
# equal to them). Null outputs are left out, as Terraform leaves them out of state.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
  }
}

variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

run "off_by_default" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
    }
  }

  variables {
    tailscale_oauth_client_secret = null
  }

  assert {
    condition     = length(kubernetes_namespace_v1.tailscale) == 0 && length(helm_release.tailscale_operator) == 0 && length(kubernetes_ingress_v1.flyte_tailnet) == 0
    error_message = "no Tailscale resources, and no client secret needed, when the infra root leaves the add-on off"
  }
}

run "tailnet_without_oauth" {
  command = plan


  assert {
    condition     = length(helm_release.tailscale_operator) == 1 && length(kubernetes_namespace_v1.tailscale) == 1
    error_message = "the operator is installed"
  }

  assert {
    condition     = helm_release.tailscale_operator[0].chart == "tailscale-operator" && helm_release.tailscale_operator[0].version == "1.104.2"
    error_message = "tailscale-operator 1.104.2"
  }

  assert {
    condition     = yamldecode(helm_release.tailscale_operator[0].values[0]).proxyConfig.defaultTags == "tag:k8s"
    error_message = "proxies get the configured tags"
  }

  assert {
    condition     = yamldecode(helm_release.tailscale_operator[0].values[0]).oauth == { clientId = "example-client-id" }
    error_message = "the operator uses the infra root's OAuth client ID; the secret is not in the values"
  }

  assert {
    condition     = nonsensitive(one(helm_release.tailscale_operator[0].set_sensitive).value) == "placeholder" && one(helm_release.tailscale_operator[0].set_sensitive).name == "oauth.clientSecret"
    error_message = "the client secret (this root's input) reaches the operator as a sensitive value"
  }

  assert {
    condition     = length(helm_release.traefik) == 0 && length(helm_release.oauth2_proxy) == 0 && length(helm_release.cert_manager) == 0
    error_message = "no Traefik, oauth2-proxy or cert-manager on the tailnet without OAuth"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.identityHeaders.subjectHeader == "Tailscale-User-Login" && yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.identityHeaders.emailHeader == "Tailscale-User-Login"
    error_message = "Flyte trusts the Tailscale identity header"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte_tailnet[0].spec[0].ingress_class_name == "tailscale" && toset(one(kubernetes_ingress_v1.flyte_tailnet[0].spec[0].tls).hosts) == toset(["flyte"])
    error_message = "a Tailscale ingress on the configured hostname"
  }

  assert {
    condition     = one([for p in one(one(kubernetes_ingress_v1.flyte_tailnet[0].spec[0].rule).http).path : p if p.path == "/"]).backend[0].service[0].name == "flyte-http"
    error_message = "the tailnet ingress goes straight to flyte-http"
  }

  assert {
    condition     = one([for p in one(one(kubernetes_ingress_v1.flyte_tailnet[0].spec[0].rule).http).path : p if p.path == "/"]).backend[0].service[0].port[0].number == 8090
    error_message = "on the flyte-http port"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte_tailnet[0].metadata[0].namespace == "flyte"
    error_message = "the ingress lives with the Flyte Services"
  }

  assert {
    condition     = output.load_balancer_address == null
    error_message = "no load balancer on the tailnet"
  }
}

run "tailnet_with_oauth" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale-oauth.json")) : k => v if v != null }
    }
  }

  assert {
    condition     = length(helm_release.oauth2_proxy) == 1
    error_message = "OAuth brings oauth2-proxy"
  }

  assert {
    condition     = yamldecode(helm_release.traefik[0].values[0]).service.spec.type == "ClusterIP"
    error_message = "Traefik is internal on the tailnet"
  }

  assert {
    condition     = length(helm_release.cert_manager) == 0
    error_message = "no cert-manager: Tailscale provides the certificate"
  }

  assert {
    condition     = one([for p in one(one(kubernetes_ingress_v1.flyte_tailnet[0].spec[0].rule).http).path : p if p.path == "/"]).backend[0].service[0].name == "traefik"
    error_message = "the tailnet ingress goes to Traefik"
  }

  assert {
    condition     = kubernetes_ingress_v1.flyte_tailnet[0].metadata[0].namespace == "traefik" && one([for p in one(one(kubernetes_ingress_v1.flyte_tailnet[0].spec[0].rule).http).path : p if p.path == "/"]).backend[0].service[0].port[0].number == 80
    error_message = "an Ingress can only name Services in its own namespace: with OAuth it lives in Traefik's, on port 80"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.identityHeaders.subjectHeader == "X-Auth-Request-User"
    error_message = "behind OAuth the identity comes from oauth2-proxy"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["redirect-url"] == "https://flyte.${local.infra.tailnet_domain}/oauth2/callback"
    error_message = "oauth2-proxy redirects to the callback under the tailnet URL"
  }
}

run "secret_required_when_infra_enables_tailscale" {
  command = plan

  variables {
    tailscale_oauth_client_secret = null
  }

  expect_failures = [var.tailscale_oauth_client_secret]
}
