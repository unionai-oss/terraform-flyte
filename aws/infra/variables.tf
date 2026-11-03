variable "cluster_endpoint_private_access_cidrs" {
  type        = list(string)
  description = "CIDRs (outside the VPC, for example a peered network or VPN range) allowed to reach the private EKS API endpoint on 443. Empty adds no rule; hosts inside the VPC always reach it."
  default     = []
}

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Expose the EKS API endpoint publicly (restricted to cluster_endpoint_public_access_cidrs). Off by default; turn it on when Terraform or kubectl run from a host that has no route into the VPC."
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public EKS API endpoint. Required (non-empty) when cluster_endpoint_public_access is true; use your own address, not 0.0.0.0/0."
  default     = []

  validation {
    condition     = !var.cluster_endpoint_public_access || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must list at least one CIDR when cluster_endpoint_public_access is true."
  }
}

variable "database" {
  type = object({
    allocated_storage   = optional(number, 20)
    deletion_protection = optional(bool, true)
    instance_class      = optional(string, "db.t4g.small")
    multi_az            = optional(bool, false)
    skip_final_snapshot = optional(bool, false)
  })
  description = "RDS for PostgreSQL 17 instance (encrypted, private). Deletion protection is on and a final snapshot is taken on destroy unless you change them; set both to turn the instance down."
  default     = {}
}

variable "enable_oauth" {
  type        = bool
  description = "Put oauth2-proxy (Amazon Cognito) in front of Flyte. Null follows exposure: on for public, off for tailscale."
  default     = null

  validation {
    # A public endpoint is never unauthenticated.
    condition     = !(var.exposure == "public" && var.enable_oauth == false)
    error_message = "enable_oauth cannot be false when exposure is public: a public endpoint is always behind OAuth."
  }
}

variable "enable_tailscale" {
  type        = bool
  description = "Install the Tailscale Kubernetes operator (the helm root installs it). Required when exposure is tailscale."
  default     = false

  validation {
    condition     = var.exposure != "tailscale" || var.enable_tailscale
    error_message = "exposure = \"tailscale\" requires enable_tailscale = true."
  }
}

variable "exposure" {
  type        = string
  description = "How the Flyte endpoint is reached: tailscale (tailnet only) or public (internet, behind OAuth)."
  # No default: the two modes need different inputs, and choosing one is the first decision.

  validation {
    condition     = contains(["tailscale", "public"], var.exposure)
    error_message = "exposure must be \"tailscale\" or \"public\"."
  }
}

variable "gpu_node_pool" {
  type = object({
    enabled        = optional(bool, false)
    capacity_type  = optional(string, "ON_DEMAND")
    desired_size   = optional(number, 1)
    instance_types = optional(list(string), ["g5.xlarge"])
    max_size       = optional(number, 4)
    min_size       = optional(number, 0)
  })
  description = "Optional GPU node group, tainted nvidia.com/gpu=true:NoSchedule (pods need a matching toleration). It is created with desired_size nodes (default 1), so it has a node without an autoscaler; min_size and max_size bound a cluster autoscaler or Karpenter if you install one. The EKS module ignores later changes to desired_size."
  default     = {}

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.gpu_node_pool.capacity_type)
    error_message = "gpu_node_pool.capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = 0 <= var.gpu_node_pool.min_size && var.gpu_node_pool.min_size <= var.gpu_node_pool.desired_size && var.gpu_node_pool.desired_size <= var.gpu_node_pool.max_size
    error_message = "gpu_node_pool must satisfy 0 <= min_size <= desired_size <= max_size."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version. Use one of the three most recent minor versions that EKS offers."
  default     = "1.34"
}

variable "name" {
  type        = string
  description = "Prefix for every resource name, and the EKS cluster name. Lowercase letters, digits and hyphens: it is part of S3 bucket names."
  default     = "flyte"

  validation {
    # Letters, digits and single hyphens, starting with a letter and not ending with a hyphen (RDS identifier rules).
    condition     = can(regex("^[a-z]([a-z0-9]*(-[a-z0-9]+)*)?$", var.name))
    error_message = "name must start with a lowercase letter and contain only lowercase letters, digits and single hyphens, not ending in a hyphen."
  }

  validation {
    # The EKS module creates an IAM role with name_prefix "<name>-cluster-", which IAM caps at 38 characters.
    condition     = length(var.name) <= 29
    error_message = "name must be at most 29 characters (the EKS cluster IAM role prefix <name>-cluster- is capped at 38)."
  }
}

variable "oauth" {
  type = object({
    allowed_email_domains = optional(list(string), [])
    allowed_emails        = optional(list(string), [])
  })
  description = "Who may sign in when OAuth is on: email domains and/or individual addresses. At least one entry is required then."
  default     = {}

  validation {
    condition     = !(var.exposure == "public" || coalesce(var.enable_oauth, false)) || length(var.oauth.allowed_email_domains) + length(var.oauth.allowed_emails) > 0
    error_message = "oauth.allowed_email_domains or oauth.allowed_emails must have an entry when OAuth is on, so signing in is never open to every account."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private (node and pod) subnet CIDRs, one per AZ. Pod IPs come from these, so size generously; the default is 3x /18."
  default     = ["10.0.64.0/18", "10.0.128.0/18", "10.0.192.0/18"]
}

variable "public" {
  type = object({
    acme_email = optional(string)
    hostname   = optional(string)
  })
  description = "Settings for exposure = public: the hostname Flyte is served on (you create the DNS record) and the Let's Encrypt contact email."
  default     = {}

  validation {
    condition     = var.exposure != "public" || (var.public.hostname != null && var.public.acme_email != null)
    error_message = "public.hostname and public.acme_email are required when exposure is public."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs, one per AZ. Hold only NAT gateways and internet-facing load balancers."
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "region" {
  type        = string
  description = "AWS region for all resources."
}

variable "single_nat_gateway" {
  type        = bool
  description = "Use one NAT gateway (cost-optimized) instead of one per AZ (production resilience)."
  default     = false
}

variable "system_node_pool" {
  type = object({
    instance_types = optional(list(string), ["m5.2xlarge"])
    node_count     = optional(number, 3)
  })
  description = "System node group: a fixed number of nodes. Use at least 4 vCPU / 16 GB and a non-burstable family (not t-series)."
  default     = {}

  validation {
    condition     = alltrue([for t in var.system_node_pool.instance_types : !can(regex("^t[0-9]+[a-z]*\\.", t))])
    error_message = "system_node_pool.instance_types must not be burstable t-series types."
  }

  validation {
    condition     = var.system_node_pool.node_count >= 3
    error_message = "system_node_pool.node_count must be at least 3."
  }
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged over the defaults (managed-by, stack) and applied to every resource through the provider's default_tags."
  default     = {}
}

variable "tailscale" {
  type = object({
    flyte_hostname  = optional(string, "flyte")
    mcp_hostname    = optional(string, "flyte-mcp")
    oauth_client_id = optional(string)
    tags            = optional(list(string), ["tag:k8s"])
    tailnet         = optional(string)
  })
  description = "Tailscale add-on settings, read by the helm root through the tailscale output. Used only when enable_tailscale is true. tailnet is the MagicDNS name without its domain suffix (for example tail1234); it is required when exposure is tailscale."
  default     = {}

  validation {
    condition     = !var.enable_tailscale || var.tailscale.oauth_client_id != null
    error_message = "tailscale.oauth_client_id is required when enable_tailscale is true."
  }

  validation {
    condition     = var.exposure != "tailscale" || var.tailscale.tailnet != null
    error_message = "tailscale.tailnet is required when exposure is tailscale."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. CIDR blocks can be added later but subnets cannot be resized."
  default     = "10.0.0.0/16"
}

variable "worker_node_pool" {
  type = object({
    enabled        = optional(bool, false)
    capacity_type  = optional(string, "ON_DEMAND")
    desired_size   = optional(number, 1)
    instance_types = optional(list(string), ["m5.2xlarge", "m5a.2xlarge", "m6i.2xlarge"])
    max_size       = optional(number, 10)
    min_size       = optional(number, 0)
  })
  description = "Optional worker node group for task pods. It is created with desired_size nodes (default 1), so it has a node without an autoscaler; min_size and max_size bound a cluster autoscaler or Karpenter if you install one. The EKS module ignores later changes to desired_size. When disabled, task pods run on the system nodes."
  default     = {}

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.worker_node_pool.capacity_type)
    error_message = "worker_node_pool.capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = 0 <= var.worker_node_pool.min_size && var.worker_node_pool.min_size <= var.worker_node_pool.desired_size && var.worker_node_pool.desired_size <= var.worker_node_pool.max_size
    error_message = "worker_node_pool must satisfy 0 <= min_size <= desired_size <= max_size."
  }
}
