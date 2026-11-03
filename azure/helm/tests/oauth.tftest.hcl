# OAuth (oauth.tf): oauth2-proxy, signing in against the app registration the infra root created.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a public deployment (checks.sh keeps the keys equal to infra/outputs.tf, and
# infra/tests/contract.tftest.hcl the values). Null values are dropped, as state drops them: Terraform does not store
# a root output whose value is null, so the helm root never sees one.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
  }
}

# result is computed, so it is unknown during plan unless overridden there.
override_resource {
  target          = random_password.cookie_secret
  override_during = plan
  values          = { result = join("", ["cookie", "secret"]) }
}

# A secret is never in a fixture: the tailscale scenario requires it, and it is set with TF_VAR_ in real use.
variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

run "off_by_default_on_the_tailnet" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
    }
  }

  assert {
    condition     = !local.oauth && !local.traefik
    error_message = "tailscale without enable_oauth has no OAuth and no Traefik"
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

# Every check on these inputs shares one plan: each run block re-plans the whole root against the mocks.
run "public_oauth" {
  command = plan

  assert {
    condition     = random_password.cookie_secret[0].length == 32 && random_password.cookie_secret[0].special == false
    error_message = "the cookie secret is 32 characters"
  }

  assert {
    condition     = one(helm_release.oauth2_proxy[0].set_sensitive).name == "config.cookieSecret" && one(helm_release.oauth2_proxy[0].set_sensitive).value == random_password.cookie_secret[0].result
    error_message = "the cookie secret reaches oauth2-proxy only through set_sensitive"
  }

  assert {
    condition     = helm_release.oauth2_proxy[0].chart == "oauth2-proxy" && helm_release.oauth2_proxy[0].version == "10.7.1" && helm_release.oauth2_proxy[0].namespace == "oauth2-proxy"
    error_message = "oauth2-proxy 10.7.1 in its own namespace"
  }

  assert {
    condition = (
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs.provider == "entra-id" &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["set-xauthrequest"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["skip-jwt-bearer-tokens"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["reverse-proxy"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["cookie-secure"] == true &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["redirect-url"] == "https://flyte.example.com/oauth2/callback"
    )
    error_message = "oauth2-proxy arguments"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["redirect-url"] == local.infra.oauth_callback_url
    error_message = "oauth2-proxy redirects to the callback the app registration has"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["oidc-issuer-url"] == local.infra.oauth_issuer_url && startswith(local.infra.oauth_issuer_url, "https://login.microsoftonline.com/") && endswith(local.infra.oauth_issuer_url, "/v2.0")
    error_message = "the issuer is the tenant's Entra v2.0 endpoint"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).config.clientID == local.infra.oauth_client_id
    error_message = "oauth2-proxy signs in with the application's client ID"
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
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["api-route"] == "^/flyteidl2\\.,^/flyte-mcp"
    error_message = "API paths get 401, not a sign-in redirect"
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs), "oidc-audience-claim") && !contains(keys(yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs), "oidc-extra-audience")
    error_message = "Entra v2.0 access tokens carry the client ID as aud, so no extra audience settings"
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["oidc-email-claim"] == "preferred_username"
    error_message = "users are identified by preferred_username, which Entra issues for every user, not only those with a mail attribute"
  }

  # oauth2-proxy authenticates to Entra with its pod's workload identity token, not a client secret.
  assert {
    condition = (
      yamldecode(helm_release.oauth2_proxy[0].values[0]).extraArgs["entra-id-federated-token-auth"] == true &&
      !contains(yamldecode(helm_release.oauth2_proxy[0].values[0]).config.requiredSecretKeys, "client-secret") &&
      !contains([for s in helm_release.oauth2_proxy[0].set_sensitive : s.name], "config.clientSecret")
    )
    error_message = "oauth2-proxy uses federated token auth and is given no client secret"
  }

  assert {
    condition = (
      yamldecode(helm_release.oauth2_proxy[0].values[0]).podLabels["azure.workload.identity/use"] == "true" &&
      yamldecode(helm_release.oauth2_proxy[0].values[0]).serviceAccount.annotations["azure.workload.identity/client-id"] == local.infra.oauth_client_id
    )
    error_message = "the pod is labelled for the workload identity webhook and its service account names the app registration"
  }

  assert {
    condition     = helm_release.oauth2_proxy[0].namespace == local.infra.service_accounts.oauth2_proxy.namespace && yamldecode(helm_release.oauth2_proxy[0].values[0]).serviceAccount.name == local.infra.service_accounts.oauth2_proxy.name
    error_message = "oauth2-proxy runs as the service account the app registration's federated credential names"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.externalAuthServerBaseUrl == local.infra.oauth_issuer_url &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.externalMetadataUrl == ".well-known/openid-configuration" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.clientId == local.infra.oauth_cli_client_id &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.redirectUri == local.infra.oauth_cli_redirect_uri &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.authMetadata.flyteClient.scopes == ["openid", "email", "profile", "offline_access", "${local.infra.oauth_cli_client_id}/.default"]
    )
    error_message = "runs.authMetadata points the SDK at Entra and the public client, asking for a token for this app"
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
      outputs = { for k, v in merge(jsondecode(file("tests/fixtures/public.json")), { oauth = { allowed_email_domains = [], allowed_emails = ["alice@example.com"] } }) : k => v if v != null }
    }
  }

  assert {
    condition     = yamldecode(helm_release.oauth2_proxy[0].values[0]).authenticatedEmailsFile.enabled && yamldecode(helm_release.oauth2_proxy[0].values[0]).authenticatedEmailsFile.restricted_access == "alice@example.com"
    error_message = "addresses are rendered into the authenticated emails file"
  }
}
