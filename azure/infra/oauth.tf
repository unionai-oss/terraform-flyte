# Who may reach Flyte when OAuth is on (CONVENTIONS section 7): the Microsoft Entra ID app registration that is the
# identity provider. oauth2-proxy, its OIDC client behind Traefik's forward-auth, is in the helm root's oauth.tf.
# Everything is gated on local.oauth (exposure.tf).

# The tenant of the identity running Terraform (az login); the app registration and the issuer live there.
data "azuread_client_config" "current" {}

locals {
  # Entra issues v2.0 tokens for this issuer; oauth2-proxy and Flyte's auth metadata both point at it.
  entra_issuer_url = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"

  cli_redirect_uri = "http://localhost:53593/callback"

  # The service account of the oauth2-proxy chart (helm root), named explicitly because the federated credential
  # names it; the helm root reads it from the service_accounts output.
  oauth2_proxy_namespace       = "oauth2-proxy"
  oauth2_proxy_service_account = "oauth2-proxy"
}

# One app registration serves both clients: the web platform is oauth2-proxy (confidential, authenticating with its
# pod's workload identity token instead of a secret), the public-client platform is the flyte CLI and SDK (PKCE, no
# secret). Single tenant: only this directory's users
# can sign in. Users and guests are admitted by oauth.allowed_email_domains / allowed_emails in oauth2-proxy.
resource "azuread_application" "this" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  display_name     = var.name
  sign_in_audience = "AzureADMyOrg"

  api {
    # v2.0 access tokens carry the app's client ID as aud and the v2.0 issuer, which is what oauth2-proxy checks
    # when the SDK sends a bearer token; the default (v1.0) would use a different issuer and an api:// audience.
    requested_access_token_version = 2
  }

  web {
    redirect_uris = ["${local.flyte_url}/oauth2/callback"]
  }

  # The SDK listens for the redirect on localhost:53593, the port Flyte's own tests use for the public client config.
  public_client {
    redirect_uris = [local.cli_redirect_uri]
  }
}

resource "azuread_service_principal" "this" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  client_id = azuread_application.this[0].client_id
}

# oauth2-proxy redeems authorization codes with the token AKS projects into its pod (--entra-id-federated-token-auth)
# instead of a client secret, so there is no secret to store or rotate. The subject names exactly its service account.
resource "azuread_application_federated_identity_credential" "oauth2_proxy" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  application_id = azuread_application.this[0].id
  display_name   = "${var.name}-oauth2-proxy"
  issuer         = module.aks.oidc_issuer_profile_issuer_url
  subject        = "system:serviceaccount:${local.oauth2_proxy_namespace}:${local.oauth2_proxy_service_account}"
  audiences      = ["api://AzureADTokenExchange"]
}
