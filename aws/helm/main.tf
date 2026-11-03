# The helm base: how this root reaches the cluster the infra root built, and the NVIDIA device plugin. Identical in
# terraform-flyte and terraform-union-dataplane; product releases live in flyte.tf / dataplane.tf.

# Everything this root knows about the cloud comes from the infra root's outputs. Nothing is entered by hand.
data "terraform_remote_state" "infra" {
  backend = var.infra_state.backend
  # Relative to the working directory, which is helm/ under `terraform -chdir=<cloud>/helm`.
  config = var.infra_state.config == null ? { path = "../infra/terraform.tfstate" } : var.infra_state.config
}

locals {
  # Read in one place: checks.sh requires every local.infra.<name> to be an infra output. Terraform keeps no root
  # output whose value is null in state, so such an output is missing here, not null: read one only behind the
  # condition that makes it non-null (a count, or the branch of a conditional).
  infra = data.terraform_remote_state.infra.outputs
}

# Short-lived tokens from the AWS CLI (the operator's own login); no cluster credential in state.
provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_ca_certificate)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.region]
    }
  }
}

# GPU pool only: the node group's AMI ships the driver, but pods can only request nvidia.com/gpu once the device
# plugin advertises it. Runs on the GPU nodes only (the label and taint ../infra/main.tf gives them).
resource "helm_release" "nvidia_device_plugin" {
  # Only with the GPU pool (an infra setting).
  count = local.infra.gpu_node_pool.enabled ? 1 : 0

  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.20.1"

  values = [yamlencode({
    nodeSelector = local.infra.gpu_node_selector
    # The chart's default affinity needs node-feature-discovery labels, which this cluster does not run; the node
    # selector above replaces it.
    affinity = null
    tolerations = [{
      key      = "nvidia.com/gpu"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  })]
}
