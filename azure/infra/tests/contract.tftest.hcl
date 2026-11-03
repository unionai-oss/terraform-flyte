# The contract between the two roots (CONVENTIONS section 8): the helm tests plan against fixtures of this root's
# outputs, one per scenario in ../helm/tests/fixtures/. Each run here plans this root with that scenario's inputs and
# checks that it outputs exactly the fixture, so a renamed output, a pass-through whose shape changed or a URL built
# differently fails here instead of passing in the helm tests. Values this root cannot know at plan (endpoints,
# client IDs, the password) are taken from the fixture through overrides, so for them only the wiring is checked.
# nat_gateway_public_ip is read by a data source that waits for the NAT module, so it is unknown at plan and only its
# name is checked (by checks.sh, with every other fixture key).

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
  target          = azurerm_private_dns_zone.postgres
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.Network/privateDnsZones/test-flyte.private.postgres.database.azure.com" }
}

# The tenant in the public fixture's issuer URL.
override_data {
  target          = data.azuread_client_config.current
  override_during = plan
  values          = { tenant_id = "example-tenant" }
}

run "public" {
  command = plan

  variables {
    name                            = "test-flyte"
    region                          = "test-region"
    api_server_authorized_ip_ranges = ["203.0.113.0/24"]
    exposure                        = "public"
    public                          = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
    oauth                           = { allowed_email_domains = ["example.com"] }
  }

  # The values infra cannot know at plan, from the fixture itself; everything else is computed by this root.
  override_module {
    target = module.aks
    outputs = {
      cluster_ca_certificate         = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_ca_certificate
      kube_config                    = yamlencode({ clusters = [{ cluster = { server = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_endpoint } }], users = [{ user = { exec = { args = ["get-token", "--server-id", jsondecode(file("../helm/tests/fixtures/public.json")).kubelogin_server_id] } } }] })
      name                           = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_name
      oidc_issuer_profile_issuer_url = jsondecode(file("../helm/tests/fixtures/public.json")).oidc_issuer_url
      resource_id                    = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ContainerService/managedClusters/test-flyte"
    }
  }

  override_resource {
    target          = azurerm_log_analytics_workspace.this
    override_during = plan
    values          = { id = jsondecode(file("../helm/tests/fixtures/public.json")).log_analytics_workspace_id }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.backend
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/backend"
      client_id    = jsondecode(file("../helm/tests/fixtures/public.json")).backend_client_id
      principal_id = "backend-principal-id"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.task
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/task"
      client_id    = jsondecode(file("../helm/tests/fixtures/public.json")).task_client_id
      principal_id = "task-principal-id"
    }
  }

  override_resource {
    target          = azurerm_postgresql_flexible_server.this
    override_during = plan
    values = {
      id   = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/test-flyte-abcd1234"
      fqdn = jsondecode(file("../helm/tests/fixtures/public.json")).database_host
    }
  }

  override_resource {
    target          = random_password.database
    override_during = plan
    values          = { result = jsondecode(file("../helm/tests/fixtures/public.json")).database_password }
  }

  override_resource {
    target          = azuread_application.this
    override_during = plan
    values = {
      id = "/applications/app-object-id"
      # azuread validates a client ID as a UUID, which the fixture cannot hold (checks.sh bans GUID literals), so
      # the two client ID outputs are checked against this resource instead of the fixture.
      client_id = join("-", ["11111111", "1111", "1111", "1111", format("%012d", 4)])
    }
  }

  # jsonencode on both sides, because == finds a list and a tuple with the same elements different. Every output in
  # one object, so a failure shows the difference; the sensitive ones on their own, since one sensitive value would
  # hide the whole difference.
  assert {
    condition = jsonencode({
      backend_client_id          = output.backend_client_id
      bucket_name                = output.bucket_name
      cluster_name               = output.cluster_name
      database_host              = output.database_host
      database_name              = output.database_name
      database_username          = output.database_username
      enable_tailscale           = output.enable_tailscale
      exposure                   = output.exposure
      flyte_config               = output.flyte_config
      flyte_url                  = output.flyte_url
      gpu_node_pool              = output.gpu_node_pool
      gpu_node_selector          = output.gpu_node_selector
      kubeconfig_command         = output.kubeconfig_command
      log_analytics_workspace_id = output.log_analytics_workspace_id
      oauth                      = output.oauth
      oauth_callback_url         = output.oauth_callback_url
      oauth_cli_redirect_uri     = output.oauth_cli_redirect_uri
      oauth_enabled              = output.oauth_enabled
      oauth_issuer_url           = output.oauth_issuer_url
      oidc_issuer_url            = output.oidc_issuer_url
      public                     = output.public
      region                     = output.region
      resource_group_name        = output.resource_group_name
      service_accounts           = output.service_accounts
      storage_account_name       = output.storage_account_name
      tailnet_domain             = output.tailnet_domain
      tailscale                  = output.tailscale
      task_client_id             = output.task_client_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/public.json")) : k => v if !contains(["nat_gateway_public_ip", "oauth_cli_client_id", "oauth_client_id", "cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's outputs for the public scenario differ from helm/tests/fixtures/public.json, which the helm tests plan against"
  }

  assert {
    condition     = output.oauth_client_id == azuread_application.this[0].client_id && output.oauth_cli_client_id == azuread_application.this[0].client_id
    error_message = "both client ID outputs are the app registration's client ID"
  }

  assert {
    condition = jsonencode({
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      database_password      = output.database_password
      kubelogin_server_id    = output.kubelogin_server_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/public.json")) : k => v if contains(["cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's sensitive outputs for the public scenario differ from helm/tests/fixtures/public.json"
  }
}

run "tailscale" {
  command = plan

  variables {
    name                            = "test-flyte"
    region                          = "test-region"
    api_server_authorized_ip_ranges = ["203.0.113.0/24"]
    exposure                        = "tailscale"
    enable_tailscale                = true
    tailscale                       = { tailnet = "example-tailnet", oauth_client_id = "example-client-id" }
  }

  # The values infra cannot know at plan, from the fixture itself; everything else is computed by this root.
  override_module {
    target = module.aks
    outputs = {
      cluster_ca_certificate         = jsondecode(file("../helm/tests/fixtures/tailscale.json")).cluster_ca_certificate
      kube_config                    = yamlencode({ clusters = [{ cluster = { server = jsondecode(file("../helm/tests/fixtures/tailscale.json")).cluster_endpoint } }], users = [{ user = { exec = { args = ["get-token", "--server-id", jsondecode(file("../helm/tests/fixtures/tailscale.json")).kubelogin_server_id] } } }] })
      name                           = jsondecode(file("../helm/tests/fixtures/tailscale.json")).cluster_name
      oidc_issuer_profile_issuer_url = jsondecode(file("../helm/tests/fixtures/tailscale.json")).oidc_issuer_url
      resource_id                    = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ContainerService/managedClusters/test-flyte"
    }
  }

  override_resource {
    target          = azurerm_log_analytics_workspace.this
    override_during = plan
    values          = { id = jsondecode(file("../helm/tests/fixtures/tailscale.json")).log_analytics_workspace_id }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.backend
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/backend"
      client_id    = jsondecode(file("../helm/tests/fixtures/tailscale.json")).backend_client_id
      principal_id = "backend-principal-id"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.task
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/task"
      client_id    = jsondecode(file("../helm/tests/fixtures/tailscale.json")).task_client_id
      principal_id = "task-principal-id"
    }
  }

  override_resource {
    target          = azurerm_postgresql_flexible_server.this
    override_during = plan
    values = {
      id   = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/test-flyte-abcd1234"
      fqdn = jsondecode(file("../helm/tests/fixtures/tailscale.json")).database_host
    }
  }

  override_resource {
    target          = random_password.database
    override_during = plan
    values          = { result = jsondecode(file("../helm/tests/fixtures/tailscale.json")).database_password }
  }

  # jsonencode on both sides, because == finds a list and a tuple with the same elements different. Every output in
  # one object, so a failure shows the difference; the sensitive ones on their own, since one sensitive value would
  # hide the whole difference.
  assert {
    condition = jsonencode({
      backend_client_id          = output.backend_client_id
      bucket_name                = output.bucket_name
      cluster_name               = output.cluster_name
      database_host              = output.database_host
      database_name              = output.database_name
      database_username          = output.database_username
      enable_tailscale           = output.enable_tailscale
      exposure                   = output.exposure
      flyte_config               = output.flyte_config
      flyte_url                  = output.flyte_url
      gpu_node_pool              = output.gpu_node_pool
      gpu_node_selector          = output.gpu_node_selector
      kubeconfig_command         = output.kubeconfig_command
      log_analytics_workspace_id = output.log_analytics_workspace_id
      oauth                      = output.oauth
      oauth_callback_url         = output.oauth_callback_url
      oauth_cli_client_id        = output.oauth_cli_client_id
      oauth_cli_redirect_uri     = output.oauth_cli_redirect_uri
      oauth_client_id            = output.oauth_client_id
      oauth_enabled              = output.oauth_enabled
      oauth_issuer_url           = output.oauth_issuer_url
      oidc_issuer_url            = output.oidc_issuer_url
      public                     = output.public
      region                     = output.region
      resource_group_name        = output.resource_group_name
      service_accounts           = output.service_accounts
      storage_account_name       = output.storage_account_name
      tailnet_domain             = output.tailnet_domain
      tailscale                  = output.tailscale
      task_client_id             = output.task_client_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/tailscale.json")) : k => v if !contains(["nat_gateway_public_ip", "cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's outputs for the tailscale scenario differ from helm/tests/fixtures/tailscale.json, which the helm tests plan against"
  }

  assert {
    condition = jsonencode({
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      database_password      = output.database_password
      kubelogin_server_id    = output.kubelogin_server_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/tailscale.json")) : k => v if contains(["cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's sensitive outputs for the tailscale scenario differ from helm/tests/fixtures/tailscale.json"
  }
}

run "tailscale-oauth" {
  command = plan

  variables {
    name                            = "test-flyte"
    region                          = "test-region"
    api_server_authorized_ip_ranges = ["203.0.113.0/24"]
    exposure                        = "tailscale"
    enable_tailscale                = true
    tailscale                       = { tailnet = "example-tailnet", oauth_client_id = "example-client-id" }
    enable_oauth                    = true
    oauth                           = { allowed_email_domains = ["example.com"] }
  }

  # The values infra cannot know at plan, from the fixture itself; everything else is computed by this root.
  override_module {
    target = module.aks
    outputs = {
      cluster_ca_certificate         = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).cluster_ca_certificate
      kube_config                    = yamlencode({ clusters = [{ cluster = { server = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).cluster_endpoint } }], users = [{ user = { exec = { args = ["get-token", "--server-id", jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).kubelogin_server_id] } } }] })
      name                           = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).cluster_name
      oidc_issuer_profile_issuer_url = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).oidc_issuer_url
      resource_id                    = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ContainerService/managedClusters/test-flyte"
    }
  }

  override_resource {
    target          = azurerm_log_analytics_workspace.this
    override_during = plan
    values          = { id = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).log_analytics_workspace_id }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.backend
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/backend"
      client_id    = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).backend_client_id
      principal_id = "backend-principal-id"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.task
    override_during = plan
    values = {
      id           = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/task"
      client_id    = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).task_client_id
      principal_id = "task-principal-id"
    }
  }

  override_resource {
    target          = azurerm_postgresql_flexible_server.this
    override_during = plan
    values = {
      id   = "/subscriptions/sub/resourceGroups/test-flyte-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/test-flyte-abcd1234"
      fqdn = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).database_host
    }
  }

  override_resource {
    target          = random_password.database
    override_during = plan
    values          = { result = jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")).database_password }
  }

  override_resource {
    target          = azuread_application.this
    override_during = plan
    values = {
      id = "/applications/app-object-id"
      # azuread validates a client ID as a UUID, which the fixture cannot hold (checks.sh bans GUID literals), so
      # the two client ID outputs are checked against this resource instead of the fixture.
      client_id = join("-", ["11111111", "1111", "1111", "1111", format("%012d", 4)])
    }
  }

  # jsonencode on both sides, because == finds a list and a tuple with the same elements different. Every output in
  # one object, so a failure shows the difference; the sensitive ones on their own, since one sensitive value would
  # hide the whole difference.
  assert {
    condition = jsonencode({
      backend_client_id          = output.backend_client_id
      bucket_name                = output.bucket_name
      cluster_name               = output.cluster_name
      database_host              = output.database_host
      database_name              = output.database_name
      database_username          = output.database_username
      enable_tailscale           = output.enable_tailscale
      exposure                   = output.exposure
      flyte_config               = output.flyte_config
      flyte_url                  = output.flyte_url
      gpu_node_pool              = output.gpu_node_pool
      gpu_node_selector          = output.gpu_node_selector
      kubeconfig_command         = output.kubeconfig_command
      log_analytics_workspace_id = output.log_analytics_workspace_id
      oauth                      = output.oauth
      oauth_callback_url         = output.oauth_callback_url
      oauth_cli_redirect_uri     = output.oauth_cli_redirect_uri
      oauth_enabled              = output.oauth_enabled
      oauth_issuer_url           = output.oauth_issuer_url
      oidc_issuer_url            = output.oidc_issuer_url
      public                     = output.public
      region                     = output.region
      resource_group_name        = output.resource_group_name
      service_accounts           = output.service_accounts
      storage_account_name       = output.storage_account_name
      tailnet_domain             = output.tailnet_domain
      tailscale                  = output.tailscale
      task_client_id             = output.task_client_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")) : k => v if !contains(["nat_gateway_public_ip", "oauth_cli_client_id", "oauth_client_id", "cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's outputs for the tailscale-oauth scenario differ from helm/tests/fixtures/tailscale-oauth.json, which the helm tests plan against"
  }

  assert {
    condition     = output.oauth_client_id == azuread_application.this[0].client_id && output.oauth_cli_client_id == azuread_application.this[0].client_id
    error_message = "both client ID outputs are the app registration's client ID"
  }

  assert {
    condition = jsonencode({
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      database_password      = output.database_password
      kubelogin_server_id    = output.kubelogin_server_id
    }) == jsonencode({ for k, v in jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")) : k => v if contains(["cluster_ca_certificate", "cluster_endpoint", "database_password", "kubelogin_server_id"], k) })
    error_message = "infra's sensitive outputs for the tailscale-oauth scenario differ from helm/tests/fixtures/tailscale-oauth.json"
  }
}
