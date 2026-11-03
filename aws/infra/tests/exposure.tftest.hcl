# Exposure modes (exposure.tf): the validations, and the mode and URL the helm root builds the front door from.

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
  name     = "test-flyte"
  region   = "us-east-2"
  exposure = "public"
  public   = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
  oauth    = { allowed_email_domains = ["example.com"] }
}

run "rejects_unknown_exposure" {
  command = plan

  variables {
    exposure = "internal"
  }

  expect_failures = [var.exposure]
}

run "public_requires_hostname_and_email" {
  command = plan

  variables {
    exposure = "public"
    public   = {}
    oauth    = { allowed_email_domains = ["example.com"] }
  }

  expect_failures = [var.public]
}

run "public_rejects_oauth_false" {
  command = plan

  variables {
    enable_oauth = false
  }

  expect_failures = [var.enable_oauth]
}

run "public" {
  command = plan

  assert {
    condition     = local.public && local.oauth && output.oauth_enabled && output.exposure == "public"
    error_message = "public implies OAuth, and the helm root is told both"
  }

  assert {
    condition     = local.flyte_url == "https://flyte.example.com" && output.flyte_url == "https://flyte.example.com"
    error_message = "the public URL is the hostname"
  }

  assert {
    condition     = output.oauth_callback_url == "https://flyte.example.com/oauth2/callback"
    error_message = "the callback URL is under the public host"
  }

  assert {
    condition     = output.public == { hostname = "flyte.example.com", acme_email = "admin@example.com" } && output.tailnet_domain == null
    error_message = "the helm root gets the hostname and ACME contact, and no tailnet domain without a tailnet"
  }
}

run "tailnet_url" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
    enable_oauth     = true
    oauth            = { allowed_email_domains = ["example.com"] }
  }

  assert {
    condition     = local.flyte_url == "https://flyte.${local.tailnet_domain}" && local.tailnet_domain == join(".", ["tail1234", "ts", "net"]) && output.tailnet_domain == local.tailnet_domain
    error_message = "on the tailnet the URL is https on the MagicDNS name"
  }

  assert {
    condition     = local.oauth && !local.public && output.oauth_enabled && output.exposure == "tailscale"
    error_message = "enable_oauth turns OAuth on in tailscale mode"
  }
}
