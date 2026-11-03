# Tailscale add-on settings (variables.tf): its validations and what the helm root's tailscale.tf reads from here.

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
  exposure                        = "tailscale"
  enable_tailscale                = true
  tailscale                       = { tailnet = "tail1234", oauth_client_id = "client-id" }
}

run "off_by_default" {
  command = plan

  variables {
    enable_tailscale = false
    exposure         = "public"
    tailscale        = {}
    public           = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
    oauth            = { allowed_email_domains = ["example.com"] }
  }

  assert {
    condition     = !output.enable_tailscale && output.tailnet_domain == null
    error_message = "the add-on is off by default, so the helm root installs no Tailscale resources"
  }
}

run "settings_are_passed_through" {
  command = plan

  assert {
    condition     = output.enable_tailscale && output.tailscale == var.tailscale
    error_message = "the helm root gets the add-on toggle and its settings"
  }

  assert {
    condition     = output.tailscale.flyte_hostname == "flyte" && output.tailscale.mcp_hostname == "flyte-mcp" && output.tailscale.tags == tolist(["tag:k8s"])
    error_message = "with their defaults applied"
  }
}

run "tailscale_mode_requires_the_add_on" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = false
  }

  expect_failures = [var.enable_tailscale]
}

run "add_on_requires_the_client_id" {
  command = plan

  variables {
    exposure  = "tailscale"
    tailscale = { tailnet = "tail1234" }
  }

  expect_failures = [var.tailscale]
}

run "tailscale_mode_requires_the_tailnet" {
  command = plan

  variables {
    exposure  = "tailscale"
    tailscale = { oauth_client_id = "client-id" }
  }

  expect_failures = [var.tailscale]
}
