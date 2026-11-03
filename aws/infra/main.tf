# The base: network and cluster from the endorsed upstream modules. Identical in terraform-flyte and
# terraform-union-dataplane; product resources live in flyte.tf / dataplane.tf.

# Credentials come from the standard AWS environment/profile chain; nothing is configured here.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Suffix for globally unique names (S3 buckets, Cognito domains), so two copies can run side by side.
resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  tags = merge({ "managed-by" = "terraform", "stack" = var.name }, var.tags)

  # How the cluster API is reached, named once because terraform test cannot read a module's inputs. The private
  # endpoint is only reachable from inside the VPC and from what the cluster security group admits, so the rule for
  # the extra CIDRs exists only when there are some.
  cluster_endpoint = {
    private_access = true
    public_access  = var.cluster_endpoint_public_access
    public_cidrs   = var.cluster_endpoint_public_access_cidrs
    security_group_rules = length(var.cluster_endpoint_private_access_cidrs) == 0 ? {} : {
      private_endpoint = {
        description = "Kubernetes API from the private access CIDRs"
        type        = "ingress"
        protocol    = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_blocks = var.cluster_endpoint_private_access_cidrs
      }
    }
  }

  # Nodes and pods live in the private subnets only; named once so a test can pin it (terraform test cannot read a
  # module's inputs).
  cluster_subnet_ids = module.vpc.private_subnets

  # IRSA (the OIDC provider) is what lets pods assume IAM roles without node-wide credentials.
  enable_irsa = true

  # One AZ per private subnet.
  azs = slice(data.aws_availability_zones.available.names, 0, length(var.private_subnet_cidrs))

  # The label that marks the GPU pool's nodes, set on the pool below and output for the helm root, whose NVIDIA
  # device plugin selects on it (helm/main.tf).
  gpu_node_selector = { "node-pool" = "gpu" }

  # Optional pools exist only when enabled. A managed node group only changes size when a cluster autoscaler or
  # Karpenter is installed, which this folder does not do, so an enabled pool is created with desired_size nodes
  # (default 1) rather than zero; min_size (default 0) lets an autoscaler empty an idle pool. The EKS module ignores
  # later changes to desired_size, so it never fights an autoscaler.
  eks_managed_node_groups = merge(
    {
      system = {
        instance_types = var.system_node_pool.instance_types
        min_size       = var.system_node_pool.node_count
        max_size       = var.system_node_pool.node_count
        desired_size   = var.system_node_pool.node_count
      }
    },
    var.worker_node_pool.enabled ? {
      worker = {
        instance_types = var.worker_node_pool.instance_types
        capacity_type  = var.worker_node_pool.capacity_type
        min_size       = var.worker_node_pool.min_size
        max_size       = var.worker_node_pool.max_size
        desired_size   = var.worker_node_pool.desired_size
      }
    } : {},
    var.gpu_node_pool.enabled ? {
      gpu = {
        instance_types = var.gpu_node_pool.instance_types
        capacity_type  = var.gpu_node_pool.capacity_type
        # The NVIDIA AMI ships the driver; the taint keeps pods that do not tolerate it off these expensive nodes.
        ami_type     = "AL2023_x86_64_NVIDIA"
        labels       = local.gpu_node_selector
        min_size     = var.gpu_node_pool.min_size
        max_size     = var.gpu_node_pool.max_size
        desired_size = var.gpu_node_pool.desired_size
        taints = {
          gpu = {
            key    = "nvidia.com/gpu"
            value  = "true"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {},
  )
}

# Community VPC module: subnet, route-table and NAT-per-AZ wiring plus the EKS subnet tags.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# Community EKS module: cluster, IRSA OIDC provider, managed node groups and the node role. Its managed node
# groups attach AmazonEC2ContainerRegistryReadOnly to the node role, which lets kubelet pull images from ECR.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = local.cluster_subnet_ids

  # Private by default; the helm and kubernetes providers (and kubectl) need a route to the endpoint, so either
  # public access can be switched on, restricted to your CIDRs, or a VPC-connected host in the private access
  # CIDRs can run Terraform.
  endpoint_private_access         = local.cluster_endpoint.private_access
  endpoint_public_access          = local.cluster_endpoint.public_access
  endpoint_public_access_cidrs    = local.cluster_endpoint.public_cidrs
  security_group_additional_rules = local.cluster_endpoint.security_group_rules

  enable_irsa                              = local.enable_irsa
  enable_cluster_creator_admin_permissions = true

  # The three add-ons Kubernetes needs; nothing here uses a PersistentVolumeClaim, so no EBS CSI driver.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = local.eks_managed_node_groups
}
