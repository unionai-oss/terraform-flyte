# Base wiring (main.tf): names, tags, node pools, endpoint access and the validations. Plans against mock
# providers; nothing is created.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["zone-a", "zone-b", "zone-c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = format("%012d", 1)
      arn        = format("arn:aws:iam::%012d:user/test", 1)
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = format("arn:aws:iam::%012d:role/test", 1)
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "random" {}

# Computed values the assertions (and the rendered Helm values) need at plan time.
override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "abcd1234"
  }
}

override_resource {
  target          = aws_iam_role.workload
  override_during = plan
  values = {
    arn = format("arn:aws:iam::%012d:role/test", 1)
  }
}

override_resource {
  target          = aws_db_instance.this
  override_during = plan
  values = {
    address  = "db.example.com"
    endpoint = "db.example.com:5432"
  }
}

override_resource {
  target          = aws_cognito_user_pool.this
  override_during = plan
  values = {
    id = "pool-id"
  }
}

override_resource {
  target          = aws_cognito_user_pool_client.cli
  override_during = plan
  values = {
    id = "cli-client-id"
  }
}

override_resource {
  target          = aws_cognito_user_pool_client.proxy
  override_during = plan
  values = {
    id            = "client-id"
    client_secret = join("-", ["client", "secret", "value"])
  }
}

variables {
  name             = "test-flyte"
  region           = "us-east-2"
  exposure         = "tailscale"
  enable_tailscale = true
  tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
  tags             = { team = "data" }
}

run "defaults" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = local.tags == { "managed-by" = "terraform", "stack" = "test-flyte", "team" = "data" }
    error_message = "tags must merge managed-by and stack with var.tags"
  }

  assert {
    condition     = length(local.azs) == 3
    error_message = "one AZ per private subnet"
  }

  assert {
    condition     = keys(local.eks_managed_node_groups) == ["system"]
    error_message = "only the system node group exists by default"
  }

  assert {
    condition     = local.eks_managed_node_groups.system.min_size == 3 && local.eks_managed_node_groups.system.max_size == 3
    error_message = "the system node group has three fixed nodes"
  }

  assert {
    condition     = module.vpc.name == "test-flyte"
    error_message = "the VPC is named after var.name"
  }

  assert {
    condition     = local.cluster_endpoint.private_access && !local.cluster_endpoint.public_access && length(local.cluster_endpoint.public_cidrs) == 0 && length(local.cluster_endpoint.security_group_rules) == 0
    error_message = "private endpoint only, and no extra security group rule, unless asked"
  }
}

run "cluster_is_wired_privately" {
  command = plan

  # Distinct, known subnet lists so the test can tell the private ones from the public ones.
  override_module {
    target = module.vpc
    outputs = {
      vpc_id          = "vpc-test"
      private_subnets = ["subnet-private-a", "subnet-private-b", "subnet-private-c"]
      public_subnets  = ["subnet-public-a", "subnet-public-b", "subnet-public-c"]
    }
  }

  # The ARN is only read from the module's OIDC provider, which exists only when enable_irsa is true.
  override_resource {
    target          = module.eks.aws_iam_openid_connect_provider.oidc_provider
    override_during = plan
    values = {
      arn = format("arn:aws:iam::%012d:oidc-provider/test", 1)
    }
  }

  assert {
    condition     = local.cluster_subnet_ids == ["subnet-private-a", "subnet-private-b", "subnet-private-c"]
    error_message = "EKS nodes go into the private subnets, never the public ones"
  }

  assert {
    condition     = local.enable_irsa
    error_message = "IRSA must be on: the dataplane role is assumed through the cluster's OIDC provider"
  }

  assert {
    condition     = module.eks.oidc_provider_arn == format("arn:aws:iam::%012d:oidc-provider/test", 1)
    error_message = "the EKS module must create the IRSA OIDC provider"
  }
}

run "optional_pools_start_with_one_node" {
  command = plan

  variables {
    worker_node_pool = { enabled = true, capacity_type = "SPOT" }
    gpu_node_pool    = { enabled = true }
  }

  assert {
    condition     = toset(keys(local.eks_managed_node_groups)) == toset(["gpu", "system", "worker"])
    error_message = "enabled pools are added"
  }

  # No autoscaler is installed, so desired_size is the size an enabled pool actually has.
  assert {
    condition = (
      local.eks_managed_node_groups.worker.min_size == 0 && local.eks_managed_node_groups.worker.desired_size == 1 && local.eks_managed_node_groups.worker.max_size == 10 &&
      local.eks_managed_node_groups.gpu.min_size == 0 && local.eks_managed_node_groups.gpu.desired_size == 1 && local.eks_managed_node_groups.gpu.max_size == 4
    )
    error_message = "an enabled optional pool starts with one node and may be scaled down to zero by an autoscaler"
  }

  assert {
    condition     = local.eks_managed_node_groups.worker.capacity_type == "SPOT"
    error_message = "worker capacity type is passed through"
  }

  assert {
    condition     = local.eks_managed_node_groups.gpu.taints.gpu == { key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }
    error_message = "GPU nodes are tainted nvidia.com/gpu=true:NoSchedule"
  }

  assert {
    condition     = local.eks_managed_node_groups.gpu.labels == { "node-pool" = "gpu" }
    error_message = "GPU nodes carry the label the helm root's NVIDIA device plugin selects on"
  }

  assert {
    condition     = output.gpu_node_pool.enabled && output.gpu_node_pool.capacity_type == "ON_DEMAND"
    error_message = "the helm root is told the GPU pool is enabled (it installs the device plugin then)"
  }
}

run "pool_sizes_pass_through" {
  command = plan

  variables {
    worker_node_pool = { enabled = true, min_size = 2, desired_size = 3, max_size = 5 }
    gpu_node_pool    = { enabled = true, min_size = 1, desired_size = 2, max_size = 2 }
  }

  assert {
    condition = (
      local.eks_managed_node_groups.worker.min_size == 2 && local.eks_managed_node_groups.worker.desired_size == 3 && local.eks_managed_node_groups.worker.max_size == 5 &&
      local.eks_managed_node_groups.gpu.min_size == 1 && local.eks_managed_node_groups.gpu.desired_size == 2 && local.eks_managed_node_groups.gpu.max_size == 2
    )
    error_message = "min_size, desired_size and max_size reach the node groups"
  }
}

run "rejects_worker_desired_above_max" {
  command = plan

  variables {
    worker_node_pool = { enabled = true, desired_size = 11 }
  }

  expect_failures = [var.worker_node_pool]
}

run "rejects_worker_min_above_desired" {
  command = plan

  variables {
    worker_node_pool = { enabled = true, min_size = 2 }
  }

  expect_failures = [var.worker_node_pool]
}

run "rejects_gpu_desired_above_max" {
  command = plan

  variables {
    gpu_node_pool = { enabled = true, desired_size = 5 }
  }

  expect_failures = [var.gpu_node_pool]
}

run "rejects_gpu_negative_min" {
  command = plan

  variables {
    gpu_node_pool = { enabled = true, min_size = -1 }
  }

  expect_failures = [var.gpu_node_pool]
}

run "public_endpoint_with_cidrs" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  variables {
    cluster_endpoint_public_access       = true
    cluster_endpoint_public_access_cidrs = ["192.0.2.0/24"]
  }

  assert {
    condition     = contains(var.cluster_endpoint_public_access_cidrs, "192.0.2.0/24")
    error_message = "the CIDR list is accepted"
  }

  assert {
    condition     = local.cluster_endpoint.public_access && local.cluster_endpoint.private_access && toset(local.cluster_endpoint.public_cidrs) == toset(["192.0.2.0/24"])
    error_message = "the EKS module gets the public access flag and CIDRs from the variables"
  }
}

run "private_endpoint_cidrs_open_443" {
  command = plan

  variables {
    cluster_endpoint_private_access_cidrs = ["198.51.100.0/24"]
  }

  assert {
    condition = (
      toset(local.cluster_endpoint.security_group_rules.private_endpoint.cidr_blocks) == toset(["198.51.100.0/24"]) &&
      local.cluster_endpoint.security_group_rules.private_endpoint.from_port == 443 &&
      local.cluster_endpoint.security_group_rules.private_endpoint.to_port == 443 &&
      local.cluster_endpoint.security_group_rules.private_endpoint.type == "ingress"
    )
    error_message = "the private access CIDRs get an ingress rule on 443 of the cluster security group"
  }
}

run "rejects_bad_gpu_capacity_type" {
  command = plan

  variables {
    gpu_node_pool = { enabled = true, capacity_type = "RESERVED" }
  }

  expect_failures = [var.gpu_node_pool]
}

run "public_endpoint_needs_cidrs" {
  command = plan

  variables {
    cluster_endpoint_public_access = true
  }

  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

run "rejects_burstable_system_nodes" {
  command = plan

  variables {
    system_node_pool = { instance_types = ["t3.xlarge"] }
  }

  expect_failures = [var.system_node_pool]
}

run "rejects_small_system_pool" {
  command = plan

  variables {
    system_node_pool = { node_count = 2 }
  }

  expect_failures = [var.system_node_pool]
}

run "rejects_bad_capacity_type" {
  command = plan

  variables {
    worker_node_pool = { capacity_type = "RESERVED" }
  }

  expect_failures = [var.worker_node_pool]
}

run "rejects_uppercase_name" {
  command = plan

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "rejects_name_starting_with_a_digit" {
  command = plan

  variables {
    name = "1flyte"
  }

  expect_failures = [var.name]
}

run "rejects_name_ending_with_a_hyphen" {
  command = plan

  variables {
    name = "flyte-"
  }

  expect_failures = [var.name]
}

run "rejects_name_with_double_hyphen" {
  command = plan

  variables {
    name = "a--b"
  }

  expect_failures = [var.name]
}

run "accepts_longest_name" {
  command = plan

  variables {
    # 29 characters: the EKS cluster IAM role prefix "<name>-cluster-" then hits IAM's 38 character cap exactly.
    name = "abcdefghijklmnopqrstuvwxyzabc"
  }

  assert {
    condition     = length(var.name) == 29 && module.vpc.name == var.name
    error_message = "a 29 character name plans"
  }
}

run "rejects_long_name" {
  command = plan

  variables {
    name = "abcdefghijklmnopqrstuvwxyzabcd"
  }

  expect_failures = [var.name]
}
