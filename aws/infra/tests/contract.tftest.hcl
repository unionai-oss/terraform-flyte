# The helm root's tests read this root's outputs from the fixtures in ../helm/tests/fixtures (one per scenario). This
# file plans this root with each scenario's inputs and requires every output to equal the fixture, so the helm tests
# cannot pass against outputs this root does not produce. checks.sh separately requires the fixture keys to be exactly
# the output names.
#
# Values that are unknown until apply (cluster endpoint and CA, ARNs, generated IDs and passwords) are overridden with
# the fixture's own values, so for those this checks the wiring (which attribute reaches which output) and not the
# value. The three fixtures share them; they are read from public.json.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["zone-a", "zone-b", "zone-c"]
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::example-account-id:role/test"
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = jsondecode(file("../helm/tests/fixtures/public.json")).account_id
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster_certificate_authority_data = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_ca_certificate
    cluster_endpoint                   = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_endpoint
    cluster_name                       = jsondecode(file("../helm/tests/fixtures/public.json")).cluster_name
    node_security_group_id             = "sg-nodes"
    oidc_provider                      = "oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE"
    oidc_provider_arn                  = jsondecode(file("../helm/tests/fixtures/public.json")).oidc_provider_arn
  }
}

override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "abcd1234"
  }
}

override_resource {
  target          = random_password.database
  override_during = plan
  values = {
    result = jsondecode(file("../helm/tests/fixtures/public.json")).database_password
  }
}

override_resource {
  target          = aws_iam_role.workload["backend"]
  override_during = plan
  values = {
    arn = jsondecode(file("../helm/tests/fixtures/public.json")).backend_role_arn
  }
}

override_resource {
  target          = aws_iam_role.workload["task"]
  override_during = plan
  values = {
    arn = jsondecode(file("../helm/tests/fixtures/public.json")).task_role_arn
  }
}

override_resource {
  target          = aws_db_instance.this
  override_during = plan
  values = {
    address = jsondecode(file("../helm/tests/fixtures/public.json")).database_host
  }
}

override_resource {
  target          = aws_cognito_user_pool.this
  override_during = plan
  values = {
    id = "us-east-2_example"
  }
}

override_resource {
  target          = aws_cognito_user_pool_client.cli
  override_during = plan
  values = {
    id = jsondecode(file("../helm/tests/fixtures/public.json")).oauth_cli_client_id
  }
}

override_resource {
  target          = aws_cognito_user_pool_client.proxy
  override_during = plan
  values = {
    id            = jsondecode(file("../helm/tests/fixtures/public.json")).oauth_client_id
    client_secret = jsondecode(file("../helm/tests/fixtures/public.json")).oauth_client_secret
  }
}

variables {
  name   = "test-flyte"
  region = "us-east-2"
}

run "public" {
  command = plan

  variables {
    exposure = "public"
    public   = { hostname = "flyte.example.com", acme_email = "admin@example.com" }
    oauth    = { allowed_email_domains = ["example.com"] }
  }

  # jsonencode on both sides: == between a list and a tuple of the same values is false.
  assert {
    condition = jsonencode({
      account_id             = output.account_id
      backend_role_arn       = output.backend_role_arn
      bucket_name            = output.bucket_name
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      cluster_name           = output.cluster_name
      database_host          = output.database_host
      database_name          = output.database_name
      database_password      = nonsensitive(output.database_password)
      database_username      = output.database_username
      enable_tailscale       = output.enable_tailscale
      exposure               = output.exposure
      flyte_config           = output.flyte_config
      flyte_url              = output.flyte_url
      gpu_node_pool          = output.gpu_node_pool
      gpu_node_selector      = output.gpu_node_selector
      kubeconfig_command     = output.kubeconfig_command
      oauth                  = output.oauth
      oauth_callback_url     = output.oauth_callback_url
      oauth_cli_client_id    = output.oauth_cli_client_id
      oauth_cli_redirect_uri = output.oauth_cli_redirect_uri
      oauth_client_id        = output.oauth_client_id
      oauth_client_secret    = nonsensitive(output.oauth_client_secret)
      oauth_enabled          = output.oauth_enabled
      oauth_issuer_url       = output.oauth_issuer_url
      oidc_provider_arn      = output.oidc_provider_arn
      public                 = output.public
      region                 = output.region
      service_accounts       = output.service_accounts
      tailnet_domain         = output.tailnet_domain
      tailscale              = output.tailscale
      task_role_arn          = output.task_role_arn
    }) == jsonencode(jsondecode(file("../helm/tests/fixtures/public.json")))
    error_message = "the outputs of a public deployment differ from ../helm/tests/fixtures/public.json"
  }
}

run "tailscale" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "example", oauth_client_id = "example-client-id" }
  }

  assert {
    condition = jsonencode({
      account_id             = output.account_id
      backend_role_arn       = output.backend_role_arn
      bucket_name            = output.bucket_name
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      cluster_name           = output.cluster_name
      database_host          = output.database_host
      database_name          = output.database_name
      database_password      = nonsensitive(output.database_password)
      database_username      = output.database_username
      enable_tailscale       = output.enable_tailscale
      exposure               = output.exposure
      flyte_config           = output.flyte_config
      flyte_url              = output.flyte_url
      gpu_node_pool          = output.gpu_node_pool
      gpu_node_selector      = output.gpu_node_selector
      kubeconfig_command     = output.kubeconfig_command
      oauth                  = output.oauth
      oauth_callback_url     = output.oauth_callback_url
      oauth_cli_client_id    = output.oauth_cli_client_id
      oauth_cli_redirect_uri = output.oauth_cli_redirect_uri
      oauth_client_id        = output.oauth_client_id
      oauth_client_secret    = output.oauth_client_secret == null ? null : nonsensitive(output.oauth_client_secret)
      oauth_enabled          = output.oauth_enabled
      oauth_issuer_url       = output.oauth_issuer_url
      oidc_provider_arn      = output.oidc_provider_arn
      public                 = output.public
      region                 = output.region
      service_accounts       = output.service_accounts
      tailnet_domain         = output.tailnet_domain
      tailscale              = output.tailscale
      task_role_arn          = output.task_role_arn
    }) == jsonencode(jsondecode(file("../helm/tests/fixtures/tailscale.json")))
    error_message = "the outputs of a tailnet deployment without OAuth differ from ../helm/tests/fixtures/tailscale.json"
  }
}

run "tailscale_oauth" {
  command = plan

  variables {
    exposure         = "tailscale"
    enable_tailscale = true
    tailscale        = { tailnet = "example", oauth_client_id = "example-client-id" }
    enable_oauth     = true
    oauth            = { allowed_email_domains = ["example.com"] }
  }

  assert {
    condition = jsonencode({
      account_id             = output.account_id
      backend_role_arn       = output.backend_role_arn
      bucket_name            = output.bucket_name
      cluster_ca_certificate = output.cluster_ca_certificate
      cluster_endpoint       = output.cluster_endpoint
      cluster_name           = output.cluster_name
      database_host          = output.database_host
      database_name          = output.database_name
      database_password      = nonsensitive(output.database_password)
      database_username      = output.database_username
      enable_tailscale       = output.enable_tailscale
      exposure               = output.exposure
      flyte_config           = output.flyte_config
      flyte_url              = output.flyte_url
      gpu_node_pool          = output.gpu_node_pool
      gpu_node_selector      = output.gpu_node_selector
      kubeconfig_command     = output.kubeconfig_command
      oauth                  = output.oauth
      oauth_callback_url     = output.oauth_callback_url
      oauth_cli_client_id    = output.oauth_cli_client_id
      oauth_cli_redirect_uri = output.oauth_cli_redirect_uri
      oauth_client_id        = output.oauth_client_id
      oauth_client_secret    = nonsensitive(output.oauth_client_secret)
      oauth_enabled          = output.oauth_enabled
      oauth_issuer_url       = output.oauth_issuer_url
      oidc_provider_arn      = output.oidc_provider_arn
      public                 = output.public
      region                 = output.region
      service_accounts       = output.service_accounts
      tailnet_domain         = output.tailnet_domain
      tailscale              = output.tailscale
      task_role_arn          = output.task_role_arn
    }) == jsonencode(jsondecode(file("../helm/tests/fixtures/tailscale-oauth.json")))
    error_message = "the outputs of a tailnet deployment with OAuth differ from ../helm/tests/fixtures/tailscale-oauth.json"
  }
}
