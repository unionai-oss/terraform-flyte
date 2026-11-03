# Who may reach Flyte when OAuth is on (CONVENTIONS section 7): oauth2-proxy in the cluster as the OIDC client behind
# Traefik's forward-auth, signing users in against the Microsoft Entra ID app registration the infra root created
# (its oauth.tf). Everything is gated on local.oauth (exposure.tf).

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
  namespace        = local.infra.service_accounts.oauth2_proxy.namespace
  create_namespace = true
  repository       = "https://oauth2-proxy.github.io/manifests"
  chart            = "oauth2-proxy"
  version          = "10.7.1"

  values = [yamlencode({
    config = {
      clientID     = local.infra.oauth_client_id
      emailDomains = local.infra.oauth.allowed_email_domains
      upstreams    = ["static://202"]
      # No client-secret key: the federated token replaces it.
      requiredSecretKeys = ["client-id", "cookie-secret"]
    }
    # Workload identity: the webhook projects a token for the app registration into pods that carry the label and run
    # as a service account annotated with its client ID.
    serviceAccount = {
      name        = local.infra.service_accounts.oauth2_proxy.name
      annotations = { "azure.workload.identity/client-id" = local.infra.oauth_client_id }
    }
    podLabels = { "azure.workload.identity/use" = "true" }
    authenticatedEmailsFile = {
      # Individual addresses are rendered into a ConfigMap the chart mounts.
      enabled           = length(local.infra.oauth.allowed_emails) > 0
      restricted_access = join("\n", local.infra.oauth.allowed_emails)
    }
    extraArgs = {
      # entra-id is oauth2-proxy's OIDC provider for Microsoft Entra ID (v7.10 and later); the generic oidc provider
      # also works but lacks its tenant check on the issuer and its group-overage handling.
      provider                      = "entra-id"
      entra-id-federated-token-auth = true
      oidc-issuer-url               = local.infra.oauth_issuer_url
      scope                         = "openid email profile"
      # Entra puts the email claim only in tokens of users whose mail attribute is set, and oauth2-proxy refuses a
      # session without an address. preferred_username (the sign-in name, the UPN for members) is in every v2.0 ID
      # and access token requested with the profile scope, so it identifies everyone and is what the allow lists
      # and X-Auth-Request-Email see, for browser sessions and bearer tokens alike.
      oidc-email-claim       = "preferred_username"
      set-xauthrequest       = true
      skip-jwt-bearer-tokens = true
      # The SDK's access token is requested with the scope "<client id>/.default", so its aud is this app's client
      # ID, the same audience oauth2-proxy already accepts for ID tokens: no extra audience is needed.
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

  set_sensitive = [{
    name  = "config.cookieSecret"
    value = random_password.cookie_secret[0].result
  }]
}
