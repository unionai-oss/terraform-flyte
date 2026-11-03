# Flyte layer (flyte.tf): storage, database and workload identity, and the outputs the helm root reads them from.

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
# Known module outputs, so assertions can compare references to them (a mocked module output is unknown at plan time).
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

override_resource {
  target          = aws_security_group.database
  override_during = plan
  values = {
    id = "sg-database"
  }
}

override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "abcd1234"
  }
}

# One distinct ARN and id per role, so an assertion can tell which role a service account or a policy attachment
# points at.
override_resource {
  target          = aws_iam_role.workload["backend"]
  override_during = plan
  values = {
    id  = "test-flyte-abcd1234-backend"
    arn = format("arn:aws:iam::%012d:role/test-flyte-abcd1234-backend", 1)
  }
}

override_resource {
  target          = aws_iam_role.workload["task"]
  override_during = plan
  values = {
    id  = "test-flyte-abcd1234-task"
    arn = format("arn:aws:iam::%012d:role/test-flyte-abcd1234-task", 1)
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
}

run "defaults" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = startswith(aws_s3_bucket.this.bucket, "test-flyte-abcd1234")
    error_message = "the bucket name starts with name and carries the suffix"
  }

  assert {
    condition     = output.bucket_name == aws_s3_bucket.this.bucket
    error_message = "bucket_name outputs the bucket"
  }

  assert {
    condition     = aws_iam_role.workload["backend"].name == "test-flyte-abcd1234-backend" && aws_iam_role.workload["task"].name == "test-flyte-abcd1234-task"
    error_message = "one role per service account, named <name>-<suffix>-<account>"
  }

  # The helm root annotates the task service account and the chart's backend account with these (its flyte.tftest.hcl).
  assert {
    condition     = output.task_role_arn == format("arn:aws:iam::%012d:role/test-flyte-abcd1234-task", 1) && output.backend_role_arn == format("arn:aws:iam::%012d:role/test-flyte-abcd1234-backend", 1)
    error_message = "task_role_arn is the task role and backend_role_arn the backend role, not the other way round"
  }

  assert {
    condition     = output.service_accounts == { backend = { namespace = "flyte", name = "flyte-backend" }, task = { namespace = "flyte", name = "flyte-task" } }
    error_message = "the helm root is told the service accounts the IRSA roles trust: flyte/flyte-backend and flyte/flyte-task"
  }

  assert {
    condition     = local.tags["stack"] == "test-flyte"
    error_message = "resources are tagged with the stack name"
  }

  assert {
    condition = (
      toset(flatten([for c in one(data.aws_iam_policy_document.trust["backend"].statement).condition : tolist(c.values) if endswith(c.variable, ":sub")])) ==
      toset(["system:serviceaccount:flyte:flyte-backend"])
    )
    error_message = "the backend role trusts only flyte/flyte-backend"
  }

  assert {
    condition = (
      toset(flatten([for c in one(data.aws_iam_policy_document.trust["task"].statement).condition : tolist(c.values) if endswith(c.variable, ":sub")])) ==
      toset(["system:serviceaccount:flyte:flyte-task"])
    )
    error_message = "the task role trusts only flyte/flyte-task"
  }

  assert {
    condition     = alltrue([for k in ["backend", "task"] : toset(flatten([for c in one(data.aws_iam_policy_document.trust[k].statement).condition : tolist(c.values) if endswith(c.variable, ":aud")])) == toset(["sts.amazonaws.com"])])
    error_message = "both trusts require the sts audience"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database.referenced_security_group_id == module.eks.node_security_group_id && aws_vpc_security_group_ingress_rule.database.from_port == 5432 && aws_vpc_security_group_ingress_rule.database.to_port == 5432
    error_message = "Postgres is reachable from the EKS node security group only"
  }

  assert {
    condition     = aws_db_instance.this.vpc_security_group_ids == toset([aws_security_group.database.id]) && !aws_db_instance.this.publicly_accessible
    error_message = "the instance uses the database security group and is private"
  }

  assert {
    condition = (
      one([for s in data.aws_iam_policy_document.bucket.statement : s if s.sid == "DenyInsecureTransport"]).effect == "Deny" &&
      one(one([for s in data.aws_iam_policy_document.bucket.statement : s if s.sid == "DenyInsecureTransport"]).condition).variable == "aws:SecureTransport" &&
      toset(one(one([for s in data.aws_iam_policy_document.bucket.statement : s if s.sid == "DenyInsecureTransport"]).condition).values) == toset(["false"])
    )
    error_message = "the bucket policy denies requests that do not use TLS"
  }

  assert {
    condition     = contains(one([for s in data.aws_iam_policy_document.storage["task"].statement : s if s.sid == "Objects"]).actions, "s3:DeleteObject") == false
    error_message = "task pods cannot delete objects"
  }

  assert {
    condition     = contains(one([for s in data.aws_iam_policy_document.storage["backend"].statement : s if s.sid == "Objects"]).actions, "s3:DeleteObject")
    error_message = "the backend can delete objects"
  }

  # Exact action lists: nothing broader (s3:*) and nothing missing.
  assert {
    condition = (
      one([for s in data.aws_iam_policy_document.storage["backend"].statement : s if s.sid == "Objects"]).actions == toset(["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]) &&
      one([for s in data.aws_iam_policy_document.storage["task"].statement : s if s.sid == "Objects"]).actions == toset(["s3:GetObject", "s3:PutObject"]) &&
      alltrue([for k in ["backend", "task"] : one([for s in data.aws_iam_policy_document.storage[k].statement : s if s.sid == "ListBucket"]).actions == toset(["s3:ListBucket"])])
    )
    error_message = "the backend may list, get, put and delete; the task role may list, get and put"
  }

  assert {
    condition     = aws_iam_role_policy.storage["backend"].role == "test-flyte-abcd1234-backend" && aws_iam_role_policy.storage["task"].role == "test-flyte-abcd1234-task"
    error_message = "each storage policy is attached to its own role"
  }

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17"
    error_message = "Postgres 17"
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.small" && aws_db_instance.this.allocated_storage == 20 && aws_db_instance.this.multi_az == false
    error_message = "database defaults"
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.publicly_accessible == false
    error_message = "the database is encrypted and private"
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection && aws_db_instance.this.skip_final_snapshot == false
    error_message = "deletion protection on and a final snapshot by default"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database.from_port == 5432 && aws_vpc_security_group_ingress_rule.database.to_port == 5432
    error_message = "only Postgres is allowed in"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.database.cidr_ipv6 == null
    error_message = "no CIDR source: only a security group (the cluster nodes) is allowed in"
  }

  assert {
    condition     = output.database_host == "db.example.com" && output.database_name == aws_db_instance.this.db_name && output.database_username == aws_db_instance.this.username
    error_message = "the helm root gets the instance's host (no port), database name and user"
  }
}

run "database_can_be_turned_down" {
  command = plan

  variables {
    database = { deletion_protection = false, skip_final_snapshot = true, multi_az = true }
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == false && aws_db_instance.this.skip_final_snapshot && aws_db_instance.this.final_snapshot_identifier == null
    error_message = "the database object controls protection and the final snapshot"
  }
}

