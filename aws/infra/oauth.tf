# Who may reach Flyte when OAuth is on (CONVENTIONS section 7): an Amazon Cognito user pool as the identity
# provider. oauth2-proxy, the OIDC client behind Traefik's forward-auth, is in ../helm/oauth.tf. Everything is gated
# on local.oauth (exposure.tf).

locals {
  # Cognito issues tokens for this issuer; oauth2-proxy and Flyte's auth metadata both point at it.
  cognito_issuer_url = local.oauth ? "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this[0].id}" : null

  cli_redirect_uri = "http://localhost:53593/callback"
}

# Users are created by an administrator (README): nobody can sign themselves up.
resource "aws_cognito_user_pool" "this" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  name                = var.name
  username_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  domain       = local.unique_name
  user_pool_id = aws_cognito_user_pool.this[0].id
}

# The confidential client oauth2-proxy signs browser users in with.
resource "aws_cognito_user_pool_client" "proxy" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  name         = "${var.name}-proxy"
  user_pool_id = aws_cognito_user_pool.this[0].id

  generate_secret                      = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${local.flyte_url}/oauth2/callback"]
}

# The public client of the flyte CLI and SDK (PKCE, no secret). Flyte advertises it through runs.authMetadata. The
# SDK listens for the redirect on localhost:53593, the port Flyte's own tests use for the public client config.
resource "aws_cognito_user_pool_client" "cli" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  name         = "${var.name}-cli"
  user_pool_id = aws_cognito_user_pool.this[0].id

  generate_secret                      = false
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = [local.cli_redirect_uri]
}
