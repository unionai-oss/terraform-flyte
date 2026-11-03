# OAuth (oauth.tf): Cognito, the allowed-user validation, and what the helm root reads to configure oauth2-proxy.

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

run "off_by_default_on_the_tailnet" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
  }

  assert {
    condition     = !local.oauth && !output.oauth_enabled
    error_message = "tailscale without enable_oauth has no OAuth"
  }

  assert {
    condition     = length(aws_cognito_user_pool.this) == 0 && length(aws_cognito_user_pool_client.proxy) == 0 && length(aws_cognito_user_pool_domain.this) == 0
    error_message = "no identity provider resources"
  }

  assert {
    condition     = output.oauth_callback_url == null
    error_message = "no callback URL without OAuth"
  }

  assert {
    condition = (
      output.oauth_client_id == null && output.oauth_client_secret == null && output.oauth_cli_client_id == null &&
      output.oauth_cli_redirect_uri == null && output.oauth_issuer_url == null
    )
    error_message = "no client, secret or issuer for the helm root without OAuth"
  }

  assert {
    condition     = yamldecode(output.flyte_config).admin.authType == "Passthrough"
    error_message = "on the tailnet without OAuth the SDK passes through (Tailscale vouches for the caller)"
  }
}

run "public_identity_provider" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  assert {
    condition     = length(aws_cognito_user_pool.this) == 1 && aws_cognito_user_pool.this[0].admin_create_user_config[0].allow_admin_create_user_only
    error_message = "the user pool admits only administrator-created users"
  }

  assert {
    condition     = toset(aws_cognito_user_pool.this[0].username_attributes) == toset(["email"])
    error_message = "the email address is the username"
  }

  assert {
    condition     = aws_cognito_user_pool_domain.this[0].domain == "test-flyte-abcd1234"
    error_message = "the Cognito domain is <name>-<suffix>"
  }

  assert {
    condition = (
      aws_cognito_user_pool_client.proxy[0].generate_secret &&
      toset(aws_cognito_user_pool_client.proxy[0].allowed_oauth_flows) == toset(["code"]) &&
      toset(aws_cognito_user_pool_client.proxy[0].allowed_oauth_scopes) == toset(["openid", "email", "profile"]) &&
      toset(aws_cognito_user_pool_client.proxy[0].callback_urls) == toset(["https://flyte.example.com/oauth2/callback"])
    )
    error_message = "a confidential client using the authorization-code flow and the callback URL"
  }

  assert {
    condition = (
      !aws_cognito_user_pool_client.cli[0].generate_secret &&
      toset(aws_cognito_user_pool_client.cli[0].allowed_oauth_flows) == toset(["code"]) &&
      toset(aws_cognito_user_pool_client.cli[0].allowed_oauth_scopes) == toset(["openid", "email", "profile"]) &&
      toset(aws_cognito_user_pool_client.cli[0].callback_urls) == toset(["http://localhost:53593/callback"])
    )
    error_message = "the CLI client is public (PKCE, no secret) and redirects to the SDK's localhost listener"
  }

  assert {
    condition = (
      output.oauth_issuer_url == "https://cognito-idp.us-east-2.amazonaws.com/pool-id" &&
      output.oauth_cli_client_id == "cli-client-id" &&
      output.oauth_cli_redirect_uri == "http://localhost:53593/callback" &&
      output.oauth_client_id == "client-id" &&
      toset(aws_cognito_user_pool_client.cli[0].callback_urls) == toset([output.oauth_cli_redirect_uri])
    )
    error_message = "the helm root gets the Cognito issuer, the proxy client, and the CLI client with the redirect it registers"
  }

  assert {
    condition     = nonsensitive(output.oauth_client_secret) == join("-", ["client", "secret", "value"])
    error_message = "the helm root gets the proxy client's secret"
  }

  assert {
    condition     = yamldecode(output.flyte_config).admin.authType == "Pkce"
    error_message = "the SDK signs in with PKCE"
  }
}

run "individual_emails" {
  command = plan

  variables {
    oauth = { allowed_emails = ["alice@example.com"] }
  }

  assert {
    condition     = output.oauth.allowed_emails == tolist(["alice@example.com"]) && length(output.oauth.allowed_email_domains) == 0
    error_message = "the allow-list reaches the helm root as given"
  }
}

run "rejects_empty_allow_lists" {
  command = plan

  variables {
    oauth = {}
  }

  expect_failures = [var.oauth]
}

run "tailscale_with_oauth_rejects_empty_allow_lists" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "tail1234", oauth_client_id = "client-id" }
    enable_oauth     = true
    oauth            = {}
  }

  expect_failures = [var.oauth]
}
