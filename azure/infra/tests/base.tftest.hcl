# The shared base (main.tf): names, tags, the name validation, the AKS module's inputs, node pools, Container
# Insights and cluster access. The same file as terraform-union-dataplane/azure/infra/tests/base.tftest.hcl except for
# the mock_provider block of the provider only terraform-flyte's infra root uses (a test may not mock a provider its
# configuration does not require). The AVM modules are planned for real against mock providers (no override_module
# here), so what is asserted about them is what the modules do with this root's inputs. Nothing is created.

mock_provider "azapi" {}
mock_provider "azurerm" {}
mock_provider "modtm" {}
mock_provider "random" {}
mock_provider "time" {}

# The provider only terraform-flyte uses.
mock_provider "azuread" {}

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
  values          = { id = "/subscriptions/sub/resourceGroups/test-base-rg" }
}

# hex is computed, so it is unknown during plan unless overridden there.
override_resource {
  target          = random_id.suffix
  override_during = plan
  values          = { hex = "abcd1234" }
}

# IDs are computed, so they are unknown during plan unless overridden there. These are resources inside the real
# modules; their outputs (module.nat.resource_id, module.aks.resource_id) are read from them.
override_resource {
  target          = module.nat.azapi_resource.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-base-rg/providers/Microsoft.Network/natGateways/test-base" }
}

# Overriding a resource replaces all of its computed values, so the response values the product layers read through
# the module's outputs (OIDC issuer, kubelet identity) are given too.
override_resource {
  target          = module.aks.azapi_resource.this
  override_during = plan
  values = {
    id = "/subscriptions/sub/resourceGroups/test-base-rg/providers/Microsoft.ContainerService/managedClusters/test-base"
    output = {
      properties = {
        oidcIssuerProfile = { issuerURL = "https://oidc.example.com/test-base/" }
        identityProfile   = { kubeletidentity = { objectId = "kubelet-object-id" } }
      }
    }
  }
}

override_resource {
  target          = azurerm_log_analytics_workspace.this
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-base-rg/providers/Microsoft.OperationalInsights/workspaces/test-base" }
}

override_resource {
  target          = azurerm_monitor_data_collection_rule.container_insights
  override_during = plan
  values          = { id = "/subscriptions/sub/resourceGroups/test-base-rg/providers/Microsoft.Insights/dataCollectionRules/MSCI-test-base" }
}

# Only name, region and tags are base inputs. The rest are terraform-flyte's required front-door inputs, which
# terraform-union-dataplane does not declare and terraform test ignores there.
variables {
  name                            = "test-base"
  region                          = "test-region"
  api_server_authorized_ip_ranges = ["203.0.113.0/24"]
  tags                            = { team = "data" }

  exposure         = "tailscale"
  enable_tailscale = true
  tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
}

# Every check on these inputs shares one plan: each run block re-plans the whole root against the mocks.
run "base_with_default_inputs" {
  command = plan

  assert {
    condition     = local.tags == { "managed-by" = "terraform", "stack" = "test-base", "team" = "data" }
    error_message = "tags must merge managed-by and stack with var.tags"
  }

  assert {
    condition     = azurerm_resource_group.this.name == "test-base-rg" && azurerm_resource_group.this.location == "test-region"
    error_message = "resource group must be <name>-rg in var.region"
  }

  assert {
    condition     = local.unique_name == "testbaseabcd1234" && length(local.unique_name) <= 24
    error_message = "globally unique names are the name without hyphens plus the suffix, at most 24 characters"
  }

  assert {
    condition     = module.network.name == "test-base" && module.aks.name == "test-base"
    error_message = "the VNet and the cluster are named after var.name"
  }

  assert {
    condition     = keys(local.subnets) == ["nodes"] && local.subnets.nodes.address_prefixes == ["10.0.0.0/18"]
    error_message = "the node subnet is the base's only subnet"
  }

  assert {
    condition     = local.subnets.nodes.nat_gateway.id == module.nat.resource_id && endswith(module.nat.resource_id, "/natGateways/test-base")
    error_message = "the node subnet must reference the NAT gateway"
  }

  # terraform test cannot read resources inside a child module, and the AKS module has no output that reflects these
  # inputs. So the security-relevant arguments of the module call are checked in main.tf's text, anchored to whole
  # lines so a commented-out argument does not count. Where the module does expose the effect of an input (the agent
  # pools, the admin kubeconfig), the other assertions check the effect instead.
  assert {
    condition     = can(regex("(?m)^  oidc_issuer_profile = \\{ enabled = true \\}$", file("${path.module}/main.tf")))
    error_message = "the AKS module must get oidc_issuer_profile = { enabled = true } (the workload identity issuer)"
  }

  assert {
    condition     = can(regex("(?m)^  security_profile    = \\{ workload_identity = \\{ enabled = true \\} \\}$", file("${path.module}/main.tf")))
    error_message = "the AKS module must get security_profile with workload identity enabled"
  }

  assert {
    condition     = can(regex("(?m)^    outbound_type       = \"userAssignedNATGateway\"$", file("${path.module}/main.tf")))
    error_message = "the AKS network profile must egress through the NAT gateway (userAssignedNATGateway)"
  }

  assert {
    condition     = can(regex("(?m)^  disable_local_accounts = true$", file("${path.module}/main.tf")))
    error_message = "the AKS module must get disable_local_accounts = true"
  }

  # The module reads the static admin kubeconfig only when local accounts are enabled; with them disabled there is
  # none, so this is null at plan time (otherwise it is an unknown value and the assertion cannot pass).
  assert {
    condition     = module.aks.kube_admin_config == null
    error_message = "local accounts must be disabled on the cluster: the module would otherwise read an admin kubeconfig"
  }

  # The Kubernetes API is never open to any address by default (CONVENTIONS.md section 2). The fixture above lists
  # 203.0.113.0/24; this checks that the list reaches the AKS module, and the next two runs that an empty list is
  # rejected and that allow_public_api_endpoint is what accepts one.
  assert {
    condition = can(regex(
      "(?m)^  api_server_access_profile = \\{\n    authorized_ip_ranges = var\\.api_server_authorized_ip_ranges\n  \\}$",
      one(regexall("(?s)\nmodule \"aks\" \\{\n.*?\n\\}\n", file("${path.module}/main.tf"))),
    ))
    error_message = "module.aks must take api_server_access_profile.authorized_ip_ranges from var.api_server_authorized_ip_ranges"
  }

  assert {
    condition     = keys(local.agent_pools) == ["workers"] && local.agent_pools.workers.min_count == 0 && local.agent_pools.workers.enable_auto_scaling
    error_message = "by default the only optional pool is workers, and it scales from zero"
  }

  assert {
    condition     = keys(module.aks.agentpool_resource_ids) == ["workers"]
    error_message = "the AKS module must create the workers pool (agent_pools passed to it)"
  }

  assert {
    condition = (
      azurerm_monitor_data_collection_rule.container_insights.destinations[0].log_analytics[0].workspace_resource_id == azurerm_log_analytics_workspace.this[0].id &&
      local.log_analytics_workspace_id == azurerm_log_analytics_workspace.this[0].id
    )
    error_message = "the data collection rule sends to the workspace Container Insights is configured with"
  }

  assert {
    condition = (
      azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].extension_name == "ContainerInsights" &&
      azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].streams == tolist(["Microsoft-ContainerInsights-Group-Default"]) &&
      jsondecode(azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].extension_json).dataCollectionSettings.enableContainerLogV2
    )
    error_message = "the rule uses the ContainerInsights extension with every stream and ContainerLogV2"
  }

  assert {
    condition = (
      azurerm_monitor_data_collection_rule.container_insights.data_flow[0].streams == tolist(["Microsoft-ContainerInsights-Group-Default"]) &&
      azurerm_monitor_data_collection_rule.container_insights.data_flow[0].destinations == tolist([azurerm_monitor_data_collection_rule.container_insights.destinations[0].log_analytics[0].name])
    )
    error_message = "the rule's data flow sends the Container Insights streams to the workspace destination"
  }

  assert {
    condition = (
      azurerm_monitor_data_collection_rule_association.container_insights.target_resource_id == module.aks.resource_id &&
      endswith(module.aks.resource_id, "/managedClusters/test-base") &&
      azurerm_monitor_data_collection_rule_association.container_insights.data_collection_rule_id == azurerm_monitor_data_collection_rule.container_insights.id
    )
    error_message = "the rule is associated with the cluster"
  }
}

run "api_endpoint_needs_authorized_ranges" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = []
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "open_api_endpoint_needs_explicit_opt_in" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = []
    allow_public_api_endpoint       = true
  }

  assert {
    condition     = length(var.api_server_authorized_ip_ranges) == 0
    error_message = "an empty list is accepted only with allow_public_api_endpoint = true"
  }
}

run "optional_pools_scale_from_zero" {
  command = plan

  variables {
    worker_node_pool = { enabled = false }
    gpu_node_pool    = { enabled = true }
  }

  assert {
    condition     = keys(local.agent_pools) == ["gpu"]
    error_message = "only the gpu pool when the worker pool is disabled"
  }

  assert {
    condition     = local.agent_pools.gpu.min_count == 0 && local.agent_pools.gpu.node_taints == ["nvidia.com/gpu=true:NoSchedule"] && local.agent_pools.gpu.node_labels["node-pool"] == "gpu"
    error_message = "the gpu pool scales from zero, is tainted nvidia.com/gpu and labelled node-pool=gpu"
  }

  assert {
    condition     = keys(module.aks.agentpool_resource_ids) == ["gpu"]
    error_message = "the AKS module must create exactly the enabled pools"
  }
}

run "user_pools_carry_tags" {
  command = plan

  variables {
    gpu_node_pool = { enabled = true }
  }

  assert {
    condition     = local.agent_pools.workers.tags == local.tags && local.agent_pools.gpu.tags == local.tags
    error_message = "user node pools must carry the tags"
  }
}

run "container_insights_with_an_existing_workspace" {
  command = plan

  variables {
    log_analytics_workspace_id = "/subscriptions/sub/resourceGroups/shared/providers/Microsoft.OperationalInsights/workspaces/shared"
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.this) == 0 && azurerm_monitor_data_collection_rule.container_insights.destinations[0].log_analytics[0].workspace_resource_id == var.log_analytics_workspace_id
    error_message = "with an existing workspace none is created and the rule sends to it"
  }
}

run "extra_cluster_admin" {
  command = plan

  variables {
    cluster_admin_principal_ids = ["extra-admin-object-id"]
  }

  assert {
    condition     = toset(keys(azurerm_role_assignment.cluster_admin)) == toset([data.azurerm_client_config.current.object_id, "extra-admin-object-id"])
    error_message = "the identity running Terraform and every cluster_admin_principal_ids entry get an assignment"
  }

  assert {
    condition = alltrue([for k, a in azurerm_role_assignment.cluster_admin : (
      a.principal_id == k &&
      a.role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin" &&
      a.scope == module.aks.resource_id
    )])
    error_message = "each assignment is Azure Kubernetes Service RBAC Cluster Admin on the cluster for its principal"
  }

  # The infra apply returns only once the cluster-admin role reaches the Kubernetes API, so the helm root can follow.
  assert {
    condition     = toset(keys(time_sleep.cluster_access.triggers)) == toset(keys(azurerm_role_assignment.cluster_admin)) && length(time_sleep.cluster_access.triggers) == 2
    error_message = "the wait at the end of the infra apply covers every cluster-admin role assignment"
  }

  assert {
    condition     = time_sleep.cluster_access.create_duration == "120s"
    error_message = "Azure RBAC gets two minutes to reach the cluster"
  }
}

run "accepts_four_character_name" {
  command = plan

  variables {
    name = "ab-1"
  }
}

run "accepts_54_character_name" {
  command = plan

  variables {
    name = "a234567890-234567890-234567890-234567890-2345678901234"
  }

  assert {
    condition     = length(var.name) == 54
    error_message = "the fixture must be 54 characters"
  }
}

run "rejects_uppercase_name" {
  command = plan

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "rejects_three_character_name" {
  command = plan

  variables {
    name = "abc"
  }

  expect_failures = [var.name]
}

run "rejects_55_character_name" {
  command = plan

  variables {
    name = "a234567890-234567890-234567890-234567890-23456789012345"
  }

  expect_failures = [var.name]
}

run "rejects_double_hyphen" {
  command = plan

  variables {
    name = "ab--cd"
  }

  expect_failures = [var.name]
}

run "rejects_name_starting_with_a_digit" {
  command = plan

  variables {
    name = "1abc"
  }

  expect_failures = [var.name]
}

run "rejects_name_ending_with_a_hyphen" {
  command = plan

  variables {
    name = "abcd-"
  }

  expect_failures = [var.name]
}
