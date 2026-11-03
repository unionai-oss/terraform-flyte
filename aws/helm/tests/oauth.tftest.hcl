# OAuth (oauth.tf): oauth2-proxy and what Flyte advertises to the SDK, on the Cognito clients of the infra root.

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

run "off_by_default_on_the_tailnet" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
    }
  }

  variables {
    tailscale_oauth_client_secret = join("", ["placeholder"])
  }

  assert {
    condition     = !local.oauth && !local.traefik
    error_message = "tailscale without OAuth has no OAuth and no Traefik"
  }

  assert {
    condition     = length(helm_release.oauth2_proxy) == 0 && length(random_password.cookie_secret) == 0
    error_message = "no oauth2-proxy"
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs), "authMetadata") && !contains(keys(yamldecode(helm_release.flyte.values[0]).console), "env") && length(kubernetes_ingress_v1.flyte_discovery) == 0
    error_message = "no auth metadata, sign-out override or discovery Ingress without OAuth"
  }
}

run "public_oauth" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = random_password.cookie_secret[0].length == 32 && random_password.cookie_secret[0].special == false
    error_message = "the cookie secret is 32 characters"
  }

  assert {
    condition     = helm_release.oauth2_proxy[0].chart == "oauth2-proxy" && helm_release.oauth2_proxy[0].version == "10.7.1" && helm_release.oauth2_proxy[0].namespace == "oauth2-proxy"
    error_message = "oauth2-proxy 10.7.1 in its own namespace"
  }

  assert {
    condition = (
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs.provider == "oidc" &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["set-xauthrequest"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["skip-jwt-bearer-tokens"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["reverse-proxy"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["cookie-secure"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["redirect-url"] == "https://flyte.example.com/oauth2/callback"
    )
    error_message = "oauth2-proxy arguments"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["oidc-issuer-url"] == "https://cognito-idp.us-east-2.amazonaws.com/us-east-2_example" && yamldecode(helm_release.oauth2_proxy[0].values[0]).config.clientID == "example-proxy-client-id"
    error_message = "oauth2-proxy signs in with the infra root's Cognito pool and proxy client"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).config.emailDomains == ["example.com"] && yamldecode(helm_release.oauth2_proxy[0].values[0]).config.upstreams == ["static://202"]
    error_message = "allowed domains and the static upstream"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).ingress.path == "/oauth2" && yamldecode(helm_release.oauth2_proxy[0].values[0]).ingress.className == "traefik" && yamldecode(helm_release.oauth2_proxy[0].values[0]).ingress.hosts == ["flyte.example.com"]
    error_message = "oauth2-proxy is served under /oauth2 on the public host"
  }

  assert {
    condition = (
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["oidc-audience-claim"] == "aud,client_id" &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["oidc-extra-audience"] == "example-cli-client-id" &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["api-route"] == "^/flyteidl2\\.,^/flyte-mcp"
    )
    error_message = "Cognito access tokens (client_id claim) from the CLI client are accepted as bearer; API paths get 401, not a redirect"
  }

  assert {
    condition     = !strcontains(helm_release.oauth2_proxy[0].values[0], "example-client-secret")
    error_message = "the client secret is passed as a sensitive value, not in the values"
  }

  assert {
    condition = (
      nonsensitive(one([for s in helm_release.oauth2_proxy[0].set_sensitive : s.value if s.name == "config.clientSecret"])) == "example-client-secret" &&
      length([for s in helm_release.oauth2_proxy[0].set_sensitive : s if s.name == "config.cookieSecret"]) == 1
    )
    error_message = "the infra root's client secret and the cookie secret reach oauth2-proxy as sensitive values"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.externalAuthServerBaseUrl == "https://cognito-idp.us-east-2.amazonaws.com/us-east-2_example" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.externalMetadataUrl == ".well-known/openid-configuration" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.clientId == "example-cli-client-id" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.redirectUri == "http://localhost:53593/callback" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.scopes == ["openid", "email", "profile"]
    )
    error_message = "runs.authMetadata points the SDK at Cognito and the public client"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0]).console.env == [{ name = "OIDC_LOGOUT_URL", value = "/oauth2/sign_out" }, { name = "LOGOUT_CLEAR_COOKIES", value = "" }]
    )
    error_message = "console sign-out goes through oauth2-proxy"
  }
}

run "individual_emails" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in merge(jsondecode(file("tests/fixtures/public.json")), {
        oauth = { allowed_email_domains = [], allowed_emails = ["alice@example.com"] }
      }) : k => v if v != null }
    }
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).authenticatedEmailsFile.enabled && yamldecode(helm_release.oauth2_proxy[0].values[0]).authenticatedEmailsFile.restricted_access == "alice@example.com"
    error_message = "addresses are rendered into the authenticated emails file"
  }

  assert {
    condition     = length(yamldecode(helm_release.oauth2_proxy[0].values[0]).config.emailDomains) == 0
    error_message = "no email domain is admitted when only addresses are allowed"
  }
}
