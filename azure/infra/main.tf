# Credentials come from `az login` or the ARM_* environment variables, and the subscription from
# ARM_SUBSCRIPTION_ID; none are set here.
provider "azurerm" {
  # Shared-key access on the storage account is off, so the provider must use Entra ID for data-plane calls.
  storage_use_azuread = true

  features {}
}

# The AVM modules create their resources through azapi, which reads the same az login / ARM_* settings.
provider "azapi" {}

data "azurerm_client_config" "current" {}

# Suffix for globally unique names: the storage account, and in terraform-union-dataplane also the registry and
# key vault.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  tags = merge({ "managed-by" = "terraform", "stack" = var.name }, var.tags)

  # Storage accounts, registries and key vaults allow only letters and digits (key vault also hyphens) and
  # storage accounts at most 24 characters: 16 from the name plus the 8-character suffix is the longest that fits.
  unique_name = "${substr(replace(lower(var.name), "-", ""), 0, 16)}${random_id.suffix.hex}"

  subnets = {
    nodes = {
      name             = "${var.name}-nodes"
      address_prefixes = [var.nodes_cidr]
      nat_gateway      = { id = module.nat.resource_id }
    }
  }

  # The label that marks the GPU pool's nodes, set on the pool below and output for the helm root, whose NVIDIA
  # device plugin selects on it (helm/main.tf).
  gpu_node_selector = { "node-pool" = "gpu" }

  # Optional pools exist only when enabled. Autoscaled pools start at zero nodes (AKS allows zero on user pools).
  agent_pools = merge(
    var.worker_node_pool.enabled ? {
      workers = {
        name                = "workers"
        mode                = "User"
        vm_size             = var.worker_node_pool.vm_size
        os_disk_size_gb     = var.worker_node_pool.os_disk_size_gb
        vnet_subnet_id      = module.network.subnets["nodes"].resource_id
        enable_auto_scaling = true
        count_of            = 0
        min_count           = 0
        max_count           = var.worker_node_pool.max_nodes
        node_labels         = { "union.ai/node-role" = "worker" }
        tags                = local.tags
      }
    } : {},
    var.gpu_node_pool.enabled ? {
      gpu = {
        name                = "gpu"
        mode                = "User"
        vm_size             = var.gpu_node_pool.vm_size
        os_disk_size_gb     = var.gpu_node_pool.os_disk_size_gb
        vnet_subnet_id      = module.network.subnets["nodes"].resource_id
        enable_auto_scaling = true
        count_of            = 0
        min_count           = 0
        max_count           = var.gpu_node_pool.max_nodes
        node_labels         = merge({ "union.ai/node-role" = "worker" }, local.gpu_node_selector)
        node_taints         = ["nvidia.com/gpu=true:NoSchedule"]
        tags                = local.tags
      }
    } : {},
  )

  log_analytics_workspace_id = coalesce(var.log_analytics_workspace_id, one(azurerm_log_analytics_workspace.this[*].id))

  # The identity running Terraform always gets cluster-admin, so it can use kubectl and helm on the cluster, and the
  # helm root, applied with the same sign-in, can install the charts.
  cluster_admins = toset(concat([data.azurerm_client_config.current.object_id], var.cluster_admin_principal_ids))

  # The cluster's Entra server application, read from the user kubeconfig the AKS module exposes. The helm root passes
  # it to kubelogin (output kubelogin_server_id), so no application ID is written into either configuration.
  kubeconfig_exec_args = yamldecode(module.aks.kube_config).users[0].user.exec.args
  kubelogin_server_id  = local.kubeconfig_exec_args[index(local.kubeconfig_exec_args, "--server-id") + 1]
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.region
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  # Skipped when an existing workspace that Container Insights already ships to is passed in.
  count = var.log_analytics_workspace_id == null ? 1 : 0

  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Nodes sit in a private subnet; the NAT gateway is their outbound path to the internet (image registries, and in
# terraform-union-dataplane the Union control plane).
# The AVM VNet module does not create one, so the AVM NAT gateway module does.
module "nat" {
  source  = "Azure/avm-res-network-natgateway/azurerm"
  version = "0.3.2"

  name      = var.name
  location  = azurerm_resource_group.this.location
  parent_id = azurerm_resource_group.this.id
  tags      = local.tags

  # StandardV2 (the module default) is not accepted as an AKS outbound NAT gateway everywhere; Standard is.
  sku_name = "Standard"
  public_ips = {
    egress = { name = "${var.name}-nat" }
  }
  # A non-zonal static public IP, so the gateway works in regions without availability zones.
  public_ip_configuration = {
    egress = { sku = "Standard", zones = [] }
  }

  enable_telemetry = false
}

# The NAT module does not export the address, so it is read back by name.
data "azurerm_public_ip" "nat" {
  name                = "${var.name}-nat"
  resource_group_name = azurerm_resource_group.this.name

  # The IP only exists once the NAT module has created it.
  depends_on = [module.nat]
}

module "network" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.3"

  name          = var.name
  location      = azurerm_resource_group.this.location
  parent_id     = azurerm_resource_group.this.id
  address_space = [var.address_space]
  subnets       = merge(local.subnets, local.product_subnets)
  tags          = local.tags

  enable_telemetry = false
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.7"

  name               = var.name
  location           = azurerm_resource_group.this.location
  parent_id          = azurerm_resource_group.this.id
  dns_prefix         = var.name
  kubernetes_version = var.kubernetes_version
  tags               = local.tags

  default_agent_pool = {
    name                = "system"
    mode                = "System"
    vm_size             = var.system_node_pool.vm_size
    count_of            = var.system_node_pool.node_count
    os_disk_size_gb     = var.system_node_pool.os_disk_size_gb
    vnet_subnet_id      = module.network.subnets["nodes"].resource_id
    enable_auto_scaling = false
  }
  agent_pools = local.agent_pools

  # Azure CNI overlay: only nodes consume subnet addresses; pods use the large overlay CIDR. The NAT gateway is
  # already attached to the node subnet through the subnets input, which AKS validates for this outbound type.
  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
  }

  # Workload identity needs both the OIDC issuer and the security profile switch.
  oidc_issuer_profile = { enabled = true }
  security_profile    = { workload_identity = { enabled = true } }

  # Entra ID with Azure RBAC for Kubernetes authorization, and no static admin credentials: access is by role
  # assignment (cluster_admins below), so there is no shared kubeconfig secret to leak.
  enable_rbac            = true
  disable_local_accounts = true
  aad_profile = {
    managed           = true
    enable_azure_rbac = true
    tenant_id         = data.azurerm_client_config.current.tenant_id
  }

  # The module drops a null authorized_ip_ranges from the request body (azapi ignore_null_property), which leaves
  # whatever ranges the cluster already has. An empty list is sent and clears them, so with
  # allow_public_api_endpoint = true and no ranges the endpoint really is open, not stuck on its old ranges.
  api_server_access_profile = {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  # Container Insights: the source of persisted (post-GC) task logs.
  addon_profile_oms_agent = {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = local.log_analytics_workspace_id
      use_aad_auth                        = true
    }
  }

  enable_telemetry = false
}

# With managed-identity auth (use_aad_auth) the Container Insights agent collects only what a data collection rule
# associated with the cluster names, and the AKS module creates one only with onboard_monitoring, which also needs a
# managed Prometheus workspace. The rule has the shape of that module's own: the ContainerInsights extension with
# ContainerLogV2, every Container Insights stream (the Default group) sent to the workspace.
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "MSCI-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kind                = "Linux"
  tags                = local.tags

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = local.log_analytics_workspace_id
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = module.aks.resource_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
}

resource "azurerm_role_assignment" "cluster_admin" {
  # One assignment per principal allowed to use the Kubernetes API.
  for_each = local.cluster_admins

  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

# The cluster-admin role assignments above need a while to reach the Kubernetes API's authorizer. Waiting here means a
# finished infra apply is a cluster the helm root can use straight away, so two applies run back to back (CI) do not
# fail with Forbidden.
resource "time_sleep" "cluster_access" {
  create_duration = "120s"

  # A reference rather than depends_on: the wait starts only after every cluster-admin assignment exists, starts
  # again when one is added, and a test can check that it covers them all.
  triggers = { for principal, assignment in azurerm_role_assignment.cluster_admin : principal => assignment.id }

  depends_on = [module.aks]
}
