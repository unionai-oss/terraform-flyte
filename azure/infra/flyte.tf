# The Flyte layer on top of the base in main.tf: object storage, managed Postgres and the workload identities of
# Flyte's service accounts. The helm root installs the chart that uses them, reading these through outputs.tf.

locals {
  # Kubernetes service accounts that reach Azure APIs: the chart's backend and the task pods' account. The federated
  # credentials below trust exactly these, and the helm root creates them from the service_accounts output, so the
  # two cannot drift apart.
  service_accounts = {
    backend = { namespace = "flyte", name = "flyte-backend" }
    task    = { namespace = "flyte", name = "flyte-task" }
  }

  # The Postgres flexible server is created inside a subnet delegated to it; main.tf merges this into the VNet.
  product_subnets = {
    postgres = {
      name             = "${var.name}-postgres"
      address_prefixes = [var.postgres_subnet_cidr]
      delegations = [{
        name               = "postgres"
        service_delegation = { name = "Microsoft.DBforPostgreSQL/flexibleServers" }
      }]
    }
  }

  database_username = "flyte"
  database_name     = "flyte"

  # Postgres server names allow hyphens (the storage account name in main.tf does not), so keep the readable form.
  database_server_name = "${var.name}-${random_id.suffix.hex}"
}

# Object storage: one container for run metadata, inputs, outputs and code bundles. No hierarchical namespace: the
# SDK and the Flyte backend use the plain blob API.
# prevent_destroy cannot be switched off by a variable and would make `terraform destroy` of a trial impossible;
# the README tells you to protect the account with a resource lock in production.
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_storage_account" "this" {
  name                            = local.unique_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  # Access is by Entra identity only (workload identity), never by account key.
  shared_access_key_enabled = false
  min_tls_version           = "TLS1_2"
  tags                      = local.tags
}

# Created through the management API (storage_account_id), so no account key is needed.
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_storage_container" "this" {
  name                  = "${var.name}-data"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Managed Postgres reachable only through the VNet: the server lives in a delegated subnet, has no public endpoint,
# and its name resolves through a private DNS zone linked to the VNet.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                = var.name
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id
  virtual_network_id  = module.network.resource_id
  tags                = local.tags
}

# The password lives in this root's state (the helm root reads it from there) and in the Helm release; use an
# encrypted remote backend for both (README).
resource "random_password" "database" {
  length  = 32
  special = false
}

# Like the storage account, no prevent_destroy (a variable cannot toggle it); the server keeps 7 days of backups.
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_postgresql_flexible_server" "this" {
  name                = local.database_server_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = var.database.version
  sku_name            = var.database.sku_name
  storage_mb          = var.database.storage_mb
  tags                = local.tags

  administrator_login    = local.database_username
  administrator_password = random_password.database.result
  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  delegated_subnet_id           = module.network.subnets["postgres"].resource_id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  backup_retention_days = 7

  lifecycle {
    # Azure picks an availability zone when none is requested and the provider then reports it as a change.
    ignore_changes = [zone]
  }

  # The zone must be linked to the VNet before the server joins it.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = local.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# backend: the chart's service account (local.service_accounts.backend).
resource "azurerm_user_assigned_identity" "backend" {
  name                = "${var.name}-backend"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# The subject names exactly one service account, so no other pod can exchange its token for this identity.
resource "azurerm_federated_identity_credential" "backend" {
  name                      = "${var.name}-backend"
  user_assigned_identity_id = azurerm_user_assigned_identity.backend.id
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:${local.service_accounts.backend.namespace}:${local.service_accounts.backend.name}"
  audience                  = ["api://AzureADTokenExchange"]
}

# task: task pods (local.service_accounts.task).
resource "azurerm_user_assigned_identity" "task" {
  name                = "${var.name}-task"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# The subject names exactly one service account, so no other pod can exchange its token for this identity.
resource "azurerm_federated_identity_credential" "task" {
  name                      = "${var.name}-task"
  user_assigned_identity_id = azurerm_user_assigned_identity.task.id
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:${local.service_accounts.task.namespace}:${local.service_accounts.task.name}"
  audience                  = ["api://AzureADTokenExchange"]
}

# The backend is granted on the account: the storage client resolves the container through account-level calls.
resource "azurerm_role_assignment" "backend_storage" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.backend.principal_id
}

# Task pods only ever touch the one container, so their grant stops there.
resource "azurerm_role_assignment" "task_storage" {
  scope                = azurerm_storage_container.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.task.principal_id
}
