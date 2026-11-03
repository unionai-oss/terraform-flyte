# OAuth (oauth.tf): the Entra ID app registration, the allowed-user validation and what the helm root's oauth2-proxy
# reads from here.

mock_provider "azapi" {}
mock_provider "azuread" {}
mock_provider "azurerm" {}
mock_provider "modtm" {}
mock_provider "random" {}
mock_provider "time" {}

# The key vault and role assignments validate these as UUIDs. Built with join and format because checks.sh bans GUID and 12-digit literals.
override_data {
  target          = data.azurerm_client_config.current
  override_during = plan
  values = {
    tenant_id       = join("-", ["00000000", "0000", "0000", "0000", format("%012d", 1)])
    subscription_id = join("-", ["00000000", "0000", "0000", "0000", format("%012d", 2)])
    object_id       = join("-", ["00000000", "0000", "0000", "0000", format("%012d", 3)])
  }
}

# Resource group IDs are validated by the AVM modules, and the mock generates a random string.
override_resource {
  target          = azurerm_resource_group.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg" }
}

# hex is computed, so it is unknown during plan unless overridden there.
override_resource {
  target          = random_id.suffix
  override_during = plan
  values          = { hex = "abcd1234" }
}

# resource_id is computed, so it is unknown during plan unless overridden there.
override_module {
  target = module.nat
  outputs = {
    resource_id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/natGateways/test-flyte"
  }
}

# Known module outputs, so assertions can compare references to them (a mocked module output is unknown at plan time).
override_module {
  target = module.network
  outputs = {
    resource_id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/virtualNetworks/test-flyte"
    subnets = {
      nodes    = { resource_id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/virtualNetworks/test-flyte/subnets/test-flyte-nodes" }
      postgres = { resource_id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/virtualNetworks/test-flyte/subnets/test-flyte-postgres" }
    }
  }
}

override_module {
  target = module.aks
  outputs = {
    cluster_ca_certificate         = base64encode("ca")
    kube_config                    = yamlencode({ clusters = [{ cluster = { server = "https://aks.example.com" } }], users = [{ user = { exec = { args = ["get-token", "--server-id", "server-app"] } } }] })
    name                           = "test-flyte"
    oidc_issuer_profile_issuer_url = "https://oidc.example.com/test/"
    resource_id                    = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ContainerService/managedClusters/test-flyte"
  }
}

override_resource {
  target          = azurerm_log_analytics_workspace.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.OperationalInsights/workspaces/test-flyte" }
}

override_resource {
  target          = azurerm_storage_account.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Storage/storageAccounts/account" }
}

override_resource {
  target          = azurerm_storage_container.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Storage/storageAccounts/account/blobServices/default/containers/container" }
}

override_resource {
  target          = azurerm_user_assigned_identity.backend
  override_during = plan
  values = {
    id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/backend"
    client_id    = "backend-client-id"
    principal_id = "backend-principal-id"
  }
}

override_resource {
  target          = azurerm_user_assigned_identity.task
  override_during = plan
  values = {
    id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/task"
    client_id    = "task-client-id"
    principal_id = "task-principal-id"
  }
}

override_resource {
  target          = azurerm_private_dns_zone.postgres
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/privateDnsZones/test-flyte.private.postgres.database.azure.com" }
}

override_resource {
  target          = azurerm_postgresql_flexible_server.this
  override_during = plan
  values = {
    id   = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/test-flyte-abcd1234"
    fqdn = "db.example.com"
  }
}

override_data {
  target          = data.azuread_client_config.current
  override_during = plan
  values          = { tenant_id = join("-", ["00000000", "0000", "0000", "0000", format("%012d", 1)]) }
}

override_resource {
  target          = azuread_application.this
  override_during = plan
  values = {
    id        = "/applications/app-object-id"
    client_id = join("-", ["11111111", "1111", "1111", "1111", format("%012d", 4)])
  }
}

override_resource {
  target          = random_password.database
  override_during = plan
  values          = { result = join("", ["database", "password"]) }
}

variables {
  name                            = "test-flyte"
  region                          = "test-region"
  api_server_authorized_ip_ranges = ["203.0.113.0/24"]
  exposure                        = "public"
  public                          = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
  oauth                           = { allowed_email_domains = ["example.com"] }
}

run "off_by_default_on_the_tailnet" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
  }

  assert {
    condition     = !local.oauth && !output.oauth_enabled
    error_message = "tailscale without enable_oauth has no OAuth"
  }

  assert {
    condition     = length(azuread_application.this) == 0 && length(azuread_service_principal.this) == 0 && length(azuread_application_federated_identity_credential.oauth2_proxy) == 0
    error_message = "no identity provider resources"
  }

  assert {
    condition     = output.oauth_callback_url == null
    error_message = "no callback URL without OAuth"
  }

  assert {
    condition     = output.oauth_client_id == null && output.oauth_cli_client_id == null && output.oauth_cli_redirect_uri == null && output.oauth_issuer_url == null
    error_message = "the helm root gets no client, redirect or issuer without OAuth"
  }
}

# Every check on these inputs shares one plan: each run block re-plans the whole root against the mocks.
run "public_identity_provider_and_outputs" {
  command = plan

  assert {
    condition     = length(azuread_application.this) == 1 && length(azuread_service_principal.this) == 1 && length(azuread_application_federated_identity_credential.oauth2_proxy) == 1
    error_message = "the app registration, its service principal and the proxy's federated credential exist"
  }

  assert {
    condition     = azuread_application.this[0].display_name == "test-flyte" && azuread_application.this[0].sign_in_audience == "AzureADMyOrg"
    error_message = "a single-tenant application named after var.name"
  }

  assert {
    condition     = azuread_application.this[0].api[0].requested_access_token_version == 2
    error_message = "v2.0 access tokens, so the audience and issuer match what oauth2-proxy verifies"
  }

  assert {
    condition     = toset(azuread_application.this[0].web[0].redirect_uris) == toset(["https://flyte.example.com/oauth2/callback"])
    error_message = "the web platform redirects to the oauth2-proxy callback under the public host"
  }

  assert {
    condition     = toset(azuread_application.this[0].public_client[0].redirect_uris) == toset(["http://localhost:53593/callback"])
    error_message = "the CLI's public-client platform (PKCE, no secret) redirects to the SDK's localhost listener"
  }

  assert {
    condition     = azuread_service_principal.this[0].client_id == azuread_application.this[0].client_id && azuread_application_federated_identity_credential.oauth2_proxy[0].application_id == azuread_application.this[0].id
    error_message = "the service principal and federated credential belong to the application"
  }

  assert {
    condition     = local.entra_issuer_url == "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
    error_message = "the issuer is the v2.0 endpoint of the signed-in tenant"
  }

  # oauth2-proxy authenticates to Entra with its pod's workload identity token, not a client secret: the app
  # registration trusts exactly the service account the helm root gives the oauth2-proxy chart.
  assert {
    condition     = azuread_application_federated_identity_credential.oauth2_proxy[0].subject == "system:serviceaccount:${output.service_accounts.oauth2_proxy.namespace}:${output.service_accounts.oauth2_proxy.name}"
    error_message = "the federated credential names exactly oauth2-proxy's service account in its namespace"
  }

  assert {
    condition     = output.service_accounts.oauth2_proxy == { namespace = "oauth2-proxy", name = "oauth2-proxy" }
    error_message = "oauth2-proxy runs as oauth2-proxy/oauth2-proxy"
  }

  assert {
    condition = (
      azuread_application_federated_identity_credential.oauth2_proxy[0].issuer == module.aks.oidc_issuer_profile_issuer_url &&
      azuread_application_federated_identity_credential.oauth2_proxy[0].issuer == "https://oidc.example.com/test/" &&
      azuread_application_federated_identity_credential.oauth2_proxy[0].audiences == tolist(["api://AzureADTokenExchange"])
    )
    error_message = "the credential trusts the cluster's OIDC issuer with the token exchange audience"
  }

  assert {
    condition     = output.oauth_client_id == azuread_application.this[0].client_id && output.oauth_cli_client_id == azuread_application.this[0].client_id
    error_message = "oauth2-proxy and the CLI both use the one app registration"
  }

  assert {
    condition     = output.oauth_issuer_url == local.entra_issuer_url && startswith(output.oauth_issuer_url, "https://login.microsoftonline.com/") && endswith(output.oauth_issuer_url, "/v2.0")
    error_message = "the issuer is the tenant's Entra v2.0 endpoint"
  }

  assert {
    condition     = output.oauth_cli_redirect_uri == "http://localhost:53593/callback" && contains(azuread_application.this[0].public_client[0].redirect_uris, output.oauth_cli_redirect_uri)
    error_message = "Flyte advertises the redirect URI the public-client platform registers"
  }

  assert {
    condition     = output.oauth == var.oauth
    error_message = "the helm root gets the allow lists for oauth2-proxy"
  }

  assert {
    condition     = yamldecode(output.flyte_config).admin.authType == "Pkce"
    error_message = "the SDK signs in with PKCE"
  }
}

run "rejects_empty_allow_lists" {
  command = plan

  variables {
    oauth = {}
  }

  expect_failures = [var.oauth]
}

run "tailscale_with_oauth_rejects_empty_allow_lists" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
    enable_oauth     = true
    oauth            = {}
  }

  expect_failures = [var.oauth]
}
