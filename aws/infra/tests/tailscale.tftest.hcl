# Tailscale add-on: its validations, and the settings the helm root installs the operator and the tailnet Ingress from
# (../helm/tailscale.tf).

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
}

run "off_by_default" {
  command = plan

  variables {
    enable_tailscale = false
    exposure         = "public"
    public           = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
    oauth            = { allowed_email_domains = ["example.com"] }
  }

  assert {
    condition     = output.enable_tailscale == false
    error_message = "the helm root is told the add-on is off"
  }
}

run "tailnet_without_oauth" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
  }

  assert {
    condition     = output.flyte_url == "https://flyte.${local.tailnet_domain}"
    error_message = "the URL is the MagicDNS name"
  }

  assert {
    condition = (
      output.enable_tailscale && output.tailscale.oauth_client_id == "client-id" && output.tailscale.tags == tolist(["tag:k8s"]) &&
      output.tailscale.flyte_hostname == "flyte" && output.tailscale.mcp_hostname == "flyte-mcp"
    )
    error_message = "the helm root gets the add-on settings with their defaults"
  }
}

run "tailnet_with_oauth" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
    enable_oauth     = true
    oauth            = { allowed_email_domains = ["example.com"] }
  }

  assert {
    condition     = length(aws_cognito_user_pool.this) == 1 && output.oauth_enabled
    error_message = "OAuth brings the identity provider"
  }

  assert {
    condition     = output.oauth_callback_url == "https://flyte.${local.tailnet_domain}/oauth2/callback"
    error_message = "the callback is under the tailnet URL"
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
