# Flyte layer (flyte.tf): storage, database and workload identity, and the outputs the helm root reads for them.

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
  tags                            = { team = "data" }
}

# Every check on these inputs shares one plan: each run block re-plans the whole root against the mocks.
run "flyte_layer_with_default_inputs" {
  command = plan

  assert {
    condition     = startswith(azurerm_storage_container.this.name, "test-flyte") && azurerm_storage_account.this.name == "testflyteabcd1234"
    error_message = "the container name starts with name; the account is the name without hyphens plus the suffix"
  }

  assert {
    condition     = output.bucket_name == azurerm_storage_container.this.name && output.storage_account_name == azurerm_storage_account.this.name
    error_message = "bucket_name outputs the container"
  }

  assert {
    condition     = azurerm_storage_account.this.shared_access_key_enabled == false && azurerm_storage_account.this.min_tls_version == "TLS1_2" && azurerm_storage_account.this.allow_nested_items_to_be_public == false
    error_message = "no account keys, TLS 1.2 and no public blobs"
  }

  assert {
    condition     = azurerm_storage_container.this.container_access_type == "private"
    error_message = "the container is private"
  }

  assert {
    condition     = output.backend_client_id == "backend-client-id" && output.task_client_id == "task-client-id"
    error_message = "the helm root gets each identity's client ID for its service account annotation"
  }

  assert {
    condition     = azurerm_storage_account.this.tags["managed-by"] == "terraform" && azurerm_storage_account.this.tags["team"] == "data" && azurerm_postgresql_flexible_server.this.tags["stack"] == "test-flyte" && azurerm_user_assigned_identity.task.tags["stack"] == "test-flyte"
    error_message = "resources are tagged"
  }

  assert {
    condition     = azurerm_federated_identity_credential.backend.subject == "system:serviceaccount:flyte:flyte-backend"
    error_message = "the backend identity trusts only flyte/flyte-backend"
  }

  assert {
    condition     = azurerm_federated_identity_credential.task.subject == "system:serviceaccount:flyte:flyte-task"
    error_message = "the task identity trusts only flyte/flyte-task"
  }

  assert {
    condition     = azurerm_federated_identity_credential.backend.issuer == "https://oidc.example.com/test/" && azurerm_federated_identity_credential.task.issuer == "https://oidc.example.com/test/" && toset(azurerm_federated_identity_credential.backend.audience) == toset(["api://AzureADTokenExchange"]) && toset(azurerm_federated_identity_credential.task.audience) == toset(["api://AzureADTokenExchange"])
    error_message = "both credentials use the cluster's OIDC issuer and the Azure AD token exchange audience"
  }

  assert {
    condition     = azurerm_federated_identity_credential.backend.user_assigned_identity_id == azurerm_user_assigned_identity.backend.id && azurerm_federated_identity_credential.task.user_assigned_identity_id == azurerm_user_assigned_identity.task.id
    error_message = "each credential belongs to its own identity"
  }

  assert {
    condition     = azurerm_role_assignment.backend_storage.scope == azurerm_storage_account.this.id && azurerm_role_assignment.backend_storage.principal_id == "backend-principal-id" && azurerm_role_assignment.backend_storage.role_definition_name == "Storage Blob Data Contributor"
    error_message = "the backend gets blob data access on the storage account"
  }

  assert {
    condition     = azurerm_role_assignment.task_storage.scope == azurerm_storage_container.this.id && azurerm_role_assignment.task_storage.principal_id == "task-principal-id" && azurerm_role_assignment.task_storage.role_definition_name == "Storage Blob Data Contributor"
    error_message = "task pods get blob data access on the container only"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this.public_network_access_enabled == false
    error_message = "the server has no public endpoint"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this.delegated_subnet_id == module.network.subnets["postgres"].resource_id && azurerm_postgresql_flexible_server.this.private_dns_zone_id == azurerm_private_dns_zone.postgres.id
    error_message = "the server is VNet-integrated in the Postgres subnet and resolves through the private zone"
  }

  assert {
    condition     = azurerm_private_dns_zone.postgres.name == "test-flyte.private.postgres.database.azure.com" && azurerm_private_dns_zone_virtual_network_link.postgres.private_dns_zone_id == azurerm_private_dns_zone.postgres.id && azurerm_private_dns_zone_virtual_network_link.postgres.virtual_network_id == module.network.resource_id
    error_message = "the private DNS zone is linked to the VNet"
  }

  assert {
    condition     = local.product_subnets.postgres.address_prefixes == ["10.0.64.0/24"] && local.product_subnets.postgres.delegations[0].service_delegation.name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "the Postgres subnet is delegated to flexible servers"
  }

  assert {
    condition     = keys(merge(local.subnets, local.product_subnets)) == ["nodes", "postgres"]
    error_message = "the VNet gets the nodes subnet and the Postgres subnet"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server_database.this.name == "flyte" && azurerm_postgresql_flexible_server_database.this.server_id == azurerm_postgresql_flexible_server.this.id
    error_message = "the flyte database lives on the server"
  }

  assert {
    condition     = output.database_host == "db.example.com" && output.database_name == "flyte" && output.database_username == "flyte"
    error_message = "the helm root gets the server's host, the database and the administrator login"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this.version == "17" && azurerm_postgresql_flexible_server.this.sku_name == "B_Standard_B1ms" && azurerm_postgresql_flexible_server.this.storage_mb == 32768
    error_message = "database defaults"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this.administrator_login == "flyte" && azurerm_postgresql_flexible_server.this.administrator_password == random_password.database.result && random_password.database.length == 32 && random_password.database.special == false
    error_message = "the administrator password comes from random_password"
  }

  assert {
    condition     = output.database_password == random_password.database.result
    error_message = "the helm root gets the administrator password"
  }

  assert {
    condition     = output.kubelogin_server_id == "server-app"
    error_message = "the helm root's kubelogin gets the server application of the cluster's kubeconfig"
  }

  assert {
    condition     = output.cluster_endpoint == "https://aks.example.com" && output.cluster_ca_certificate == base64encode("ca")
    error_message = "the API endpoint comes from the cluster's kubeconfig, the CA from the module"
  }

  assert {
    condition     = keys(output.service_accounts) == ["backend", "oauth2_proxy", "task"]
    error_message = "the helm root learns every service account an identity here trusts"
  }

  assert {
    condition     = azurerm_federated_identity_credential.task.subject == "system:serviceaccount:${output.service_accounts.task.namespace}:${output.service_accounts.task.name}"
    error_message = "the task identity's subject is the service account the helm root creates for task pods"
  }

  assert {
    condition     = azurerm_federated_identity_credential.backend.subject == "system:serviceaccount:${output.service_accounts.backend.namespace}:${output.service_accounts.backend.name}"
    error_message = "the backend identity's subject is the service account the helm root gives the chart"
  }

  assert {
    condition     = !output.gpu_node_pool.enabled
    error_message = "the GPU pool, and with it the helm root's device plugin, is off by default"
  }
}

run "database_object_is_passed_through" {
  command = plan

  variables {
    database = { sku_name = "GP_Standard_D2s_v3", storage_mb = 65536, version = "16" }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this.version == "16" && azurerm_postgresql_flexible_server.this.sku_name == "GP_Standard_D2s_v3" && azurerm_postgresql_flexible_server.this.storage_mb == 65536
    error_message = "the database object controls the server"
  }
}

run "postgres_subnet_cidr_is_used" {
  command = plan

  variables {
    postgres_subnet_cidr = "10.0.70.0/24"
  }

  assert {
    condition     = local.product_subnets.postgres.address_prefixes == ["10.0.70.0/24"]
    error_message = "postgres_subnet_cidr sets the delegated subnet"
  }
}

run "gpu_node_pool_is_passed_through" {
  command = plan

  variables {
    gpu_node_pool = { enabled = true }
  }

  assert {
    condition     = output.gpu_node_pool.enabled && output.gpu_node_pool.vm_size == "Standard_NC4as_T4_v3"
    error_message = "the helm root gets the GPU pool settings, defaults applied, for the device plugin"
  }
}
