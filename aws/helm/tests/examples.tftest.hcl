# Plans this root against each examples/aws/helm/*.tfvars (checks.sh makes its values each run's variables), once for
# each infra scenario in tests/fixtures: a helm example has to plan whichever infra example it is applied after.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# The one variable set here is a secret: examples never contain secrets (they are set with TF_VAR_ in real use), but
# the tailnet scenarios need one to pass validation.
variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

# Null outputs are left out, as Terraform leaves them out of state.
run "after_public" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
    }
  }

  assert {
    condition     = helm_release.flyte.chart == "flyte-binary"
    error_message = "the example installs Flyte"
  }
}

run "after_tailscale" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
    }
  }

  assert {
    condition     = helm_release.flyte.chart == "flyte-binary"
    error_message = "the example installs Flyte"
  }
}

run "after_tailscale_oauth" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale-oauth.json")) : k => v if v != null }
    }
  }

  assert {
    condition     = helm_release.flyte.chart == "flyte-binary"
    error_message = "the example installs Flyte"
  }
}
