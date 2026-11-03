# The helm base (main.tf): the provider configuration and the NVIDIA device plugin.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a tailnet deployment (checks.sh keeps the keys equal to infra/outputs.tf, and
# infra/tests/contract.tftest.hcl the values). Null values are dropped, as state drops them: Terraform does not store
# a root output whose value is null, so the helm root never sees one.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
  }
}

# A secret is never in a fixture: the tailscale scenario requires it, and it is set with TF_VAR_ in real use.
variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

# Every check on these inputs shares one plan: each run block re-plans the whole root against the mocks.
run "providers_and_no_device_plugin_by_default" {
  command = plan

  # terraform test cannot read a provider's configuration, so its exec arguments are checked in main.tf's text: both
  # providers sign in with kubelogin through az login, for the server application infra reads from the cluster.
  assert {
    condition     = length(regexall("(?m)^ +command += \"kubelogin\"$", file("${path.module}/main.tf"))) == 2
    error_message = "the kubernetes and helm providers both run kubelogin"
  }

  assert {
    condition     = length(regexall("(?m)^ +args += \\[\"get-token\", \"--login\", \"azurecli\", \"--server-id\", sensitive\\(local\\.infra\\.kubelogin_server_id\\)\\]$", file("${path.module}/main.tf"))) == 2
    error_message = "both get a token through az login for the cluster's Entra server application"
  }

  assert {
    condition     = length(helm_release.nvidia_device_plugin) == 0
    error_message = "no device plugin without the GPU pool"
  }
}

run "gpu_pool_installs_the_device_plugin" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in merge(jsondecode(file("tests/fixtures/tailscale.json")), { gpu_node_pool = { enabled = true, max_nodes = 4, os_disk_size_gb = 200, vm_size = "Standard_NC4as_T4_v3" } }) : k => v if v != null }
    }
  }

  assert {
    condition     = helm_release.nvidia_device_plugin[0].chart == "nvidia-device-plugin" && helm_release.nvidia_device_plugin[0].version == "0.20.1" && helm_release.nvidia_device_plugin[0].repository == "https://nvidia.github.io/k8s-device-plugin"
    error_message = "the NVIDIA device plugin chart is pinned"
  }

  # The label and taint of the GPU pool in the infra root's main.tf (its base tests check them there); the label is
  # infra's gpu_node_selector output, which its contract.tftest.hcl ties to the fixture.
  assert {
    condition = (
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).nodeSelector["node-pool"] == "gpu" &&
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).tolerations[0].key == "nvidia.com/gpu" &&
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).tolerations[0].operator == "Exists" &&
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).tolerations[0].effect == "NoSchedule"
    )
    error_message = "the plugin runs on the GPU nodes only and tolerates their taint"
  }
}
