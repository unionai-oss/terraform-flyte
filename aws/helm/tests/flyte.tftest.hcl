# Flyte layer (flyte.tf): the service accounts and the flyte-binary values, built from the infra root's bucket,
# database and IRSA roles.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

# The infra root's outputs for a tailnet deployment (infra's contract.tftest.hcl keeps the fixture equal to them).
# Null outputs are left out, as Terraform leaves them out of state.
override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = { for k, v in jsondecode(file("tests/fixtures/tailscale.json")) : k => v if v != null }
  }
}

variables {
  tailscale_oauth_client_secret = join("", ["placeholder"])
}

run "tailnet_defaults" {
  command = plan

  # Every check on these inputs shares one plan: each run block re-plans the whole root.
  # The IRSA roles trust exactly these accounts (infra's service_accounts output), so the names and the namespace
  # must match it.
  assert {
    condition = (
      kubernetes_service_account_v1.task.metadata[0].name == local.infra.service_accounts.task.name &&
      kubernetes_service_account_v1.task.metadata[0].namespace == local.infra.service_accounts.task.namespace &&
      yamldecode(helm_release.flyte.values[0]).serviceAccount.name == local.infra.service_accounts.backend.name &&
      helm_release.flyte.namespace == local.infra.service_accounts.backend.namespace
    )
    error_message = "the task account and the chart's backend account are the ones the IRSA roles trust"
  }

  assert {
    condition     = kubernetes_service_account_v1.task.metadata[0].name == "flyte-task" && yamldecode(helm_release.flyte.values[0]).serviceAccount.name == "flyte-backend"
    error_message = "task pods get the flyte-task service account, the chart's backend flyte-backend"
  }

  assert {
    condition     = kubernetes_service_account_v1.task.metadata[0].annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::example-account-id:role/test-flyte-abcd1234-task"
    error_message = "the task service account carries the task role, not the backend role"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).serviceAccount.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::example-account-id:role/test-flyte-abcd1234-backend"
    error_message = "the backend service account carries the backend role, not the task role"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).console.image.repository == "ghcr.io/unionai-oss/flyteconsole-v2" && can(regex("^[0-9a-f]{40}@sha256:[0-9a-f]{64}$", yamldecode(helm_release.flyte.values[0]).console.image.tag))
    error_message = "the console image is pinned by tag and digest"
  }

  assert {
    condition     = helm_release.flyte.chart == "flyte-binary" && helm_release.flyte.version == "v2.0.51" && helm_release.flyte.name == "flyte" && helm_release.flyte.namespace == "flyte"
    error_message = "flyte-binary v2.0.51 as release flyte in namespace flyte"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).fullnameOverride == "flyte"
    error_message = "fullnameOverride keeps the API Service named flyte-http"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0]).configuration.storage.provider == "s3" &&
      yamldecode(helm_release.flyte.values[0]).configuration.storage.metadataContainer == "test-flyte-abcd1234" &&
      yamldecode(helm_release.flyte.values[0]).configuration.storage.providerConfig.s3.region == "us-east-2" &&
      yamldecode(helm_release.flyte.values[0]).configuration.storage.providerConfig.s3.authType == "iam"
    )
    error_message = "storage is the infra root's bucket in its region, authenticated through IRSA"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.storagePrefix == "s3://test-flyte-abcd1234/runs" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].dataproxy.upload.storagePrefix == "s3://test-flyte-abcd1234/runs/uploads"
    )
    error_message = "run data and uploads live under runs/"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0]).configuration.database.postgres.host == "db.example.com" &&
      yamldecode(helm_release.flyte.values[0]).configuration.database.postgres.options == "sslmode=require" &&
      yamldecode(helm_release.flyte.values[0]).configuration.database.postgres.dbname == "flyte" &&
      yamldecode(helm_release.flyte.values[0]).configuration.database.postgres.username == "flyte"
    )
    error_message = "the database settings point at the infra root's RDS instance with TLS required"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).configuration.inline.executor.defaultK8sServiceAccount == "flyte-task"
    error_message = "task pods run as flyte-task"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).ingress.create == false
    error_message = "the chart creates no ingress"
  }

  assert {
    condition     = !contains(keys(yamldecode(helm_release.flyte.values[0]).configuration.database.postgres), "password")
    error_message = "the database password stays out of the values"
  }

  assert {
    condition = (
      one(helm_release.flyte.set_sensitive).name == "configuration.database.postgres.password" &&
      nonsensitive(one(helm_release.flyte.set_sensitive).value) == "example-database-password"
    )
    error_message = "the infra root's database password reaches the chart as a sensitive value"
  }
}

run "gpu_task_toleration_matches_the_node_taint" {
  command = plan

  override_data {
    target = data.terraform_remote_state.infra
    values = {
      outputs = { for k, v in merge(jsondecode(file("tests/fixtures/tailscale.json")), {
        gpu_node_pool = { enabled = true, capacity_type = "ON_DEMAND", desired_size = 1, instance_types = ["g5.xlarge"], max_size = 4, min_size = 0 }
      }) : k => v if v != null }
    }
  }

  # The taint the infra root gives the GPU node group (its base.tftest.hcl pins it), in Kubernetes' effect names.
  assert {
    condition = (
      length(yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"]) == 1 &&
      yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"][0] == {
        key      = "nvidia.com/gpu"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }
    )
    error_message = "GPU tasks tolerate exactly the GPU node group's taint nvidia.com/gpu=true:NoSchedule"
  }

  assert {
    condition = (
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).tolerations[0].key == yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"][0].key &&
      yamldecode(helm_release.nvidia_device_plugin[0].values[0]).tolerations[0].effect == yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"][0].effect
    )
    error_message = "the NVIDIA device plugin tolerates the same taint key and effect as GPU tasks"
  }
}
