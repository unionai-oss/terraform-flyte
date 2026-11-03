# The helm base: how this root finds the infra root and the cluster, and the NVIDIA device plugin both products need
# on the GPU pool. The same file in terraform-flyte and terraform-union-dataplane. It declares no cloud provider.

# Everything this root knows about the cloud comes from the infra root's outputs. Nothing is entered by hand.
data "terraform_remote_state" "infra" {
  backend = var.infra_state.backend
  # Relative to the working directory, which is helm/ under `terraform -chdir=<cloud>/helm`.
  config = var.infra_state.config == null ? { path = "../infra/terraform.tfstate" } : var.infra_state.config
}

locals {
  # Read in one place: checks.sh requires every local.infra.<name> to be an infra output.
  infra = data.terraform_remote_state.infra.outputs
}

# Short-lived Entra tokens from kubelogin, reusing the operator's `az login` (README: Prerequisites), so no cluster
# credential is stored in state or on disk. Local accounts are disabled on the cluster; access is the cluster-admin
# role assignment in the infra root. Remote state drops the sensitive mark, so it is put back here.
provider "kubernetes" {
  host                   = sensitive(local.infra.cluster_endpoint)
  cluster_ca_certificate = base64decode(sensitive(local.infra.cluster_ca_certificate))

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", sensitive(local.infra.kubelogin_server_id)]
  }
}

provider "helm" {
  kubernetes = {
    host                   = sensitive(local.infra.cluster_endpoint)
    cluster_ca_certificate = base64decode(sensitive(local.infra.cluster_ca_certificate))

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "kubelogin"
      args        = ["get-token", "--login", "azurecli", "--server-id", sensitive(local.infra.kubelogin_server_id)]
    }
  }
}

# GPU pool only: the AKS GPU node image ships the driver, but pods can only request nvidia.com/gpu once the device
# plugin advertises it. Runs on the GPU nodes only, tolerating their taint.
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
