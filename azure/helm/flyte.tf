# The flyte-binary Helm release on the cluster the infra root built, with the storage, database and identities it
# created (all read from local.infra, main.tf).

locals {
  # Annotations for the Traefik LoadBalancer Service (used by exposure.tf). AKS' standard load balancer needs none.
  load_balancer_annotations = {}

  # The console image the flyte-gke project pins, by tag and digest. The chart renders <repository>:<tag>, so the
  # digest rides in the tag.
  console_image_tag = "21b4f4bf69f3538a656effc9c8c95cd1450e2088@sha256:db4362ec0d3b6940be19f9fdc5c1c53dca5cc912e1463a79c0e2b9fa1b29627b"
}

resource "kubernetes_namespace_v1" "flyte" {
  metadata {
    name = local.infra.service_accounts.backend.namespace
  }
}

# Task pods run as this account (configuration.inline.executor.defaultK8sServiceAccount in the values template).
# The chart creates the backend account itself.
resource "kubernetes_service_account_v1" "task" {
  metadata {
    name      = local.infra.service_accounts.task.name
    namespace = kubernetes_namespace_v1.flyte.metadata[0].name

    annotations = {
      "azure.workload.identity/client-id" = local.infra.task_client_id
    }
  }
}

resource "helm_release" "flyte" {
  name       = "flyte"
  namespace  = kubernetes_namespace_v1.flyte.metadata[0].name
  repository = "https://flyteorg.github.io/flyte"
  chart      = "flyte-binary"
  version    = "v2.0.51"
  timeout    = 900

  values = [templatefile("${path.module}/templates/flyte-values.yaml.tmpl", {
    backend_client_id       = local.infra.backend_client_id
    backend_service_account = local.infra.service_accounts.backend.name
    claims_jwt_header       = local.identity_headers.claimsJwtHeader
    cli_client_id           = local.oauth ? local.infra.oauth_cli_client_id : ""
    cli_redirect_uri        = local.oauth ? local.infra.oauth_cli_redirect_uri : ""
    console_image_tag       = local.console_image_tag
    container               = local.infra.bucket_name
    database_host           = local.infra.database_host
    database_name           = local.infra.database_name
    database_username       = local.infra.database_username
    email_header            = local.identity_headers.emailHeader
    issuer_url              = local.oauth ? local.infra.oauth_issuer_url : ""
    namespace               = kubernetes_namespace_v1.flyte.metadata[0].name
    oauth                   = local.oauth
    storage_account         = local.infra.storage_account_name
    subject_header          = local.identity_headers.subjectHeader
    task_service_account    = kubernetes_service_account_v1.task.metadata[0].name
  })]

  # Passed separately so it stays out of the plan output.
  set_sensitive = [{
    name  = "configuration.database.postgres.password"
    value = sensitive(local.infra.database_password)
  }]
}
