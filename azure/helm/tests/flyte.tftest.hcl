# Flyte layer (flyte.tf): the flyte-binary release and its service accounts, wired to what the infra root created.

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
run "flyte_release" {
  command = plan

  assert {
    condition     = kubernetes_service_account_v1.task.metadata[0].name == "flyte-task"
    error_message = "task pods get the flyte-task service account"
  }

  assert {
    condition     = kubernetes_service_account_v1.task.metadata[0].annotations["azure.workload.identity/client-id"] == "example-task-client-id"
    error_message = "the task service account carries the task identity's client ID"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).serviceAccount.annotations["azure.workload.identity/client-id"] == "example-backend-client-id"
    error_message = "the backend service account carries the backend identity's client ID"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).serviceAccount.name == "flyte-backend"
    error_message = "the chart's service account is flyte-backend"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).console.image.repository == "ghcr.io/unionai-oss/flyteconsole-v2" && can(regex("^[0-9a-f]{40}@sha256:[0-9a-f]{64}$", yamldecode(helm_release.flyte.values[0]).console.image.tag))
    error_message = "the console image is pinned by tag and digest"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"][0].key == "nvidia.com/gpu" && yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["resource-tolerations"]["nvidia.com/gpu"][0].value == "true"
    error_message = "GPU tasks must tolerate the GPU node pool's nvidia.com/gpu=true taint."
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
      yamldecode(helm_release.flyte.values[0]).configuration.storage.provider == "azure" &&
      yamldecode(helm_release.flyte.values[0]).configuration.storage.metadataContainer == local.infra.bucket_name &&
      yamldecode(helm_release.flyte.values[0]).configuration.storage.providerConfig.azure.account == local.infra.storage_account_name &&
      !contains(keys(yamldecode(helm_release.flyte.values[0]).configuration.storage.providerConfig.azure), "key")
    )
    error_message = "storage is the container, authenticated through workload identity (no account key)"
  }

  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].runs.storagePrefix == "abfs://${local.infra.bucket_name}/runs" &&
      yamldecode(helm_release.flyte.values[0])["flyte-core-components"].dataproxy.upload.storagePrefix == "abfs://${local.infra.bucket_name}/runs/uploads"
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
    error_message = "the database settings point at the flexible server with TLS required"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).configuration.inline.executor.defaultK8sServiceAccount == "flyte-task"
    error_message = "task pods run as flyte-task"
  }

  assert {
    condition     = yamldecode(helm_release.flyte.values[0]).deployment.podLabels["azure.workload.identity/use"] == "true" && yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["default-labels"]["azure.workload.identity/use"] == "true"
    error_message = "the backend pod and every task pod carry the workload identity label"
  }

  assert {
    condition     = contains([for e in yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["default-env-vars"] : try(e.AZURE_STORAGE_ACCOUNT_NAME, "")], local.infra.storage_account_name) && contains([for e in yamldecode(helm_release.flyte.values[0]).configuration.inline.plugins.k8s["default-env-vars"] : try(e._U_EP_OVERRIDE, "")], "flyte-http.flyte:8090")
    error_message = "task pods know the storage account and keep the chart's control plane address"
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
      one(helm_release.flyte.set_sensitive).value == local.infra.database_password
    )
    error_message = "the database password from the infra state reaches the chart only through set_sensitive"
  }

  # The flyte-binary default pool (100 connections) exceeds what the default B_Standard_B1ms server accepts.
  assert {
    condition = (
      yamldecode(helm_release.flyte.values[0]).configuration.database.maxOpenConnections == 25 &&
      yamldecode(helm_release.flyte.values[0]).configuration.database.maxIdleConnections == 10
    )
    error_message = "the connection pool is capped at 25 open and 10 idle connections"
  }

  # The federated credentials in the infra root trust exactly the service accounts it outputs; these are the ones the
  # release and the task pods run as.
  assert {
    condition     = kubernetes_service_account_v1.task.metadata[0].namespace == local.infra.service_accounts.task.namespace && kubernetes_service_account_v1.task.metadata[0].name == local.infra.service_accounts.task.name
    error_message = "the task service account is the one the task identity trusts"
  }

  assert {
    condition     = helm_release.flyte.namespace == local.infra.service_accounts.backend.namespace && yamldecode(helm_release.flyte.values[0]).serviceAccount.name == local.infra.service_accounts.backend.name
    error_message = "the chart's service account, in the release namespace, is the one the backend identity trusts"
  }
}
