# The flyte-binary release and the Kubernetes objects it needs, on the bucket, database and IRSA roles the infra root
# created (../infra/flyte.tf).

locals {
  # Annotations for the Traefik LoadBalancer Service (used by exposure.tf): a Network Load Balancer instead of the
  # legacy Classic one.
  load_balancer_annotations = {
    "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
  }

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
      "eks.amazonaws.com/role-arn" = local.infra.task_role_arn
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
    backend_role_arn        = local.infra.backend_role_arn
    backend_service_account = local.infra.service_accounts.backend.name
    bucket                  = local.infra.bucket_name
    claims_jwt_header       = local.identity_headers.claimsJwtHeader
    cli_client_id           = local.oauth ? local.infra.oauth_cli_client_id : ""
    cli_redirect_uri        = local.oauth ? local.infra.oauth_cli_redirect_uri : ""
    console_image_tag       = local.console_image_tag
    database_host           = local.infra.database_host
    database_name           = local.infra.database_name
    database_username       = local.infra.database_username
    email_header            = local.identity_headers.emailHeader
    issuer_url              = local.oauth ? local.infra.oauth_issuer_url : ""
    oauth                   = local.oauth
    region                  = local.infra.region
    subject_header          = local.identity_headers.subjectHeader
    task_service_account    = local.infra.service_accounts.task.name
  })]

  # Passed separately so it stays out of the plan output.
  set_sensitive = [{
    name  = "configuration.database.postgres.password"
    value = sensitive(local.infra.database_password)
  }]

  depends_on = [kubernetes_service_account_v1.task]
}
