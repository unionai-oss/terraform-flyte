# oauth2-proxy, the OIDC client behind Traefik's forward-auth when OAuth is on (CONVENTIONS section 7). It signs users
# in against the Cognito user pool and app clients the infra root created (../infra/oauth.tf). Everything is gated
# on local.oauth (exposure.tf).

locals {
  # Also the namespace in the forward-auth address (exposure.tf).
  oauth2_proxy_namespace = "oauth2-proxy"
}

# 32 alphanumeric characters: a valid 32-byte oauth2-proxy cookie secret.
resource "random_password" "cookie_secret" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  length  = 32
  special = false
}

resource "helm_release" "oauth2_proxy" {
  # Only when OAuth is on.
  count = local.oauth ? 1 : 0

  name             = "oauth2-proxy"
  namespace        = local.oauth2_proxy_namespace
  create_namespace = true
  repository       = "https://oauth2-proxy.github.io/manifests"
  chart            = "oauth2-proxy"
  version          = "10.7.1"

  values = [yamlencode({
    config = {
      clientID     = local.infra.oauth_client_id
      emailDomains = local.infra.oauth.allowed_email_domains
      upstreams    = ["static://202"]
    }
    authenticatedEmailsFile = {
      # Individual addresses are rendered into a ConfigMap the chart mounts.
      enabled           = length(local.infra.oauth.allowed_emails) > 0
      restricted_access = join("\n", local.infra.oauth.allowed_emails)
    }
    extraArgs = {
      provider               = "oidc"
      oidc-issuer-url        = local.infra.oauth_issuer_url
      scope                  = "openid email profile"
      set-xauthrequest       = true
      skip-jwt-bearer-tokens = true
      # Cognito ID tokens carry the client in aud but access tokens (what the SDK sends as bearer) carry it in
      # client_id and have no aud; accept both claims, from the proxy client and from the CLI client.
      oidc-audience-claim = "aud,client_id"
      oidc-extra-audience = local.infra.oauth_cli_client_id
      # API callers get 401 instead of a sign-in redirect (they could not follow it).
      api-route     = join(",", local.api_route_regexes)
      reverse-proxy = true
      redirect-url  = local.infra.oauth_callback_url
      cookie-secure = true
    }
    # Served on the Flyte host under /oauth2 (sign-in, callback and the forward-auth check). No TLS block: Traefik's
    # websecure entrypoint terminates TLS with the certificate Traefik already holds for the host.
    ingress = {
      enabled   = true
      className = "traefik"
      path      = "/oauth2"
      pathType  = "Prefix"
      hosts     = [local.public ? local.infra.public.hostname : ""]
    }
  })]

  set_sensitive = [
    {
      name  = "config.clientSecret"
      value = sensitive(local.infra.oauth_client_secret)
    },
    {
      name  = "config.cookieSecret"
      value = random_password.cookie_secret[0].result
    },
  ]
}
