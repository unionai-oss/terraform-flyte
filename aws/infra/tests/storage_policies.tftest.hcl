# Which storage policy document each IRSA role carries (flyte.tf). The documents name the bucket, which is still to
# be created, so Terraform reads them only at apply and a plan cannot show which one a role policy got. This file
# applies against mock providers (nothing is created) and gives each document a distinct mock body. It has no
# plan-time overrides: a value fixed at plan and generated again at apply is an inconsistent plan.

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

# The base is not under test here, and the provider rejects the mocks' random strings where its resources expect ARNs.
override_module {
  target = module.vpc
  outputs = {
    vpc_id          = "vpc-test"
    private_subnets = ["subnet-private-a", "subnet-private-b", "subnet-private-c"]
    public_subnets  = ["subnet-public-a", "subnet-public-b", "subnet-public-c"]
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster_certificate_authority_data = base64encode("ca")
    cluster_endpoint                   = "https://eks.example.com"
    cluster_name                       = "test-flyte"
    node_security_group_id             = "sg-nodes"
    oidc_provider                      = "oidc.eks.example.com/id/TEST"
    oidc_provider_arn                  = format("arn:aws:iam::%012d:oidc-provider/oidc.eks.example.com/id/TEST", 1)
  }
}

override_data {
  target = data.aws_iam_policy_document.storage["backend"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Id\":\"backend-storage\",\"Statement\":[]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.storage["task"]
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Id\":\"task-storage\",\"Statement\":[]}"
  }
}

variables {
  name             = "test-flyte"
  region           = "us-east-2"
  exposure         = "tailscale"
  enable_tailscale = true
  tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
}

run "each_role_carries_its_own_document" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.storage["backend"].policy).Id == "backend-storage" &&
      aws_iam_role_policy.storage["backend"].role == aws_iam_role.workload["backend"].id &&
      jsondecode(aws_iam_role_policy.storage["task"].policy).Id == "task-storage" &&
      aws_iam_role_policy.storage["task"].role == aws_iam_role.workload["task"].id &&
      aws_iam_role.workload["backend"].id != aws_iam_role.workload["task"].id
    )
    error_message = "the backend role carries the backend document (with delete) and the task role the task document"
  }
}
