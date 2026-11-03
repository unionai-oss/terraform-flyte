# Plans the root against each examples/azure/helm/*.tfvars (checks.sh makes its values each run's variables), once
# against each infra scenario's fixture: a helm example has to plan whichever infra example it follows. Null values are
# dropped from the fixtures, as state drops null root outputs.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "time" {}

# The one variable set here is a secret: examples never contain secrets (they are set with TF_VAR_ in real use), but
# the tailscale scenario needs one to pass validation.
variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

run "plans_after_infra_public" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/public.json")) : k => v if v != null }
    }
  }
}

run "plans_after_infra_tailscale" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
    }
  }
}

run "plans_after_infra_tailscale_with_oauth" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale-oauth.json")) : k => v if v != null }
    }
  }
}
