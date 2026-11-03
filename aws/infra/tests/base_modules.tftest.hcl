# The base (main.tf) as the pinned vpc and eks modules receive it. Byte-identical in terraform-flyte and
# terraform-union-dataplane, like main.tf.
#
# base.tftest.hcl checks the locals main.tf passes; this file checks that the modules get them. Nothing here
# overrides module.vpc or module.eks: the real modules are planned against the mock providers. A test can only read
# a module's outputs, not the resources inside it, so where a module output reflects an argument (NAT gateways,
# subnets, node groups and their taints) the assertion reads that output. Three arguments reach nothing a mocked
# plan can read: the provider's default_tags (tags_all is unknown until apply), and the cluster's endpoint access
# and subnet_ids (the module outputs no part of the cluster's vpc_config). For those, modules_on_defaults reads main.tf
# and requires each argument to be exactly the local base.tftest.hcl checks.

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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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
}

mock_provider "random" {}

variables {
  name   = "test-base"
  region = "us-east-2"

  # terraform-flyte's required inputs (a tailnet deployment). terraform-union-dataplane declares none of them, and
  # terraform test ignores a value for a variable the configuration does not declare.
  exposure         = "tailscale"
  enable_tailscale = true
  tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
}

run "modules_on_defaults" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = length(module.vpc.natgw_ids) == 3 && length(module.vpc.private_nat_gateway_route_ids) == 3
    error_message = "one NAT gateway per AZ by default, and each private subnet routes through one"
  }

  assert {
    condition = (
      tolist([for s in module.vpc.private_subnet_objects : s.cidr_block]) == var.private_subnet_cidrs &&
      alltrue([for s in module.vpc.private_subnet_objects : s.tags["kubernetes.io/role/internal-elb"] == "1"])
    )
    error_message = "the private subnets are the private_subnet_cidrs, tagged for internal load balancers"
  }

  assert {
    condition = (
      tolist([for s in module.vpc.public_subnet_objects : s.cidr_block]) == var.public_subnet_cidrs &&
      alltrue([for s in module.vpc.public_subnet_objects : s.tags["kubernetes.io/role/elb"] == "1"])
    )
    error_message = "the public subnets are the public_subnet_cidrs, tagged for internet-facing load balancers"
  }

  assert {
    condition     = keys(module.eks.eks_managed_node_groups) == ["system"]
    error_message = "the cluster gets the system node group, and only that one by default"
  }

  assert {
    condition     = length(module.eks.eks_managed_node_groups["system"].node_group_taints) == 0
    error_message = "the system node group is untainted"
  }

  assert {
    condition     = can(regex("\\nprovider \"aws\" \\{\\n(?:[^\\n]*\\n)*?  default_tags \\{\\n    tags = local\\.tags\\n  \\}\\n", file("${path.module}/main.tf")))
    error_message = "the aws provider applies local.tags through default_tags"
  }

  assert {
    condition = alltrue([
      for argument in [
        "subnet_ids += local\\.cluster_subnet_ids",
        "endpoint_private_access += local\\.cluster_endpoint\\.private_access",
        "endpoint_public_access += local\\.cluster_endpoint\\.public_access",
        "endpoint_public_access_cidrs += local\\.cluster_endpoint\\.public_cidrs",
        "security_group_additional_rules += local\\.cluster_endpoint\\.security_group_rules",
        "enable_irsa += local\\.enable_irsa",
        "eks_managed_node_groups += local\\.eks_managed_node_groups",
      ] :
      can(regex("\\n  ${argument}\\n", regex("(?s)\\nmodule \"eks\" \\{\\n.*?\\n\\}\\n", file("${path.module}/main.tf"))))
    ])
    error_message = "module.eks gets its subnets, endpoint access, IRSA and node groups from the locals base.tftest.hcl checks"
  }
}

run "single_nat_gateway" {
  command = plan

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 1 && length(module.vpc.private_nat_gateway_route_ids) == 1
    error_message = "single_nat_gateway gives one NAT gateway, the default route of the one private route table"
  }
}

run "node_groups_optional" {
  command = plan

  variables {
    worker_node_pool = { enabled = true }
    gpu_node_pool    = { enabled = true }
  }

  assert {
    condition     = keys(module.eks.eks_managed_node_groups) == ["gpu", "system", "worker"]
    error_message = "enabled pools reach the cluster as node groups"
  }

  assert {
    condition     = module.eks.eks_managed_node_groups["gpu"].node_group_taints == toset([{ key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }])
    error_message = "the GPU node group is tainted nvidia.com/gpu=true:NoSchedule"
  }

  assert {
    condition     = module.eks.eks_managed_node_groups["gpu"].node_group_labels == tomap({ "node-pool" = "gpu" })
    error_message = "the GPU node group carries the label the NVIDIA device plugin selects on"
  }

  assert {
    condition     = length(module.eks.eks_managed_node_groups["worker"].node_group_taints) == 0
    error_message = "the worker node group is untainted"
  }
}
