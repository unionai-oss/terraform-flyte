variable "address_space" {
  type        = string
  description = "Address space of the VNet."
  default     = "10.0.0.0/16"
}

variable "allow_public_api_endpoint" {
  type        = bool
  description = "Allow api_server_authorized_ip_ranges to be empty, which leaves the public Kubernetes API endpoint open to any address (access still needs Entra ID). Off by default: list your CIDRs instead."
  default     = false
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDRs allowed to reach the Kubernetes API (the endpoint is public, nodes are private). Required (non-empty) unless allow_public_api_endpoint is true."
  default     = []

  validation {
    # An empty list on a public endpoint admits the whole internet to the API, so it has to be asked for.
    condition     = length(var.api_server_authorized_ip_ranges) > 0 || var.allow_public_api_endpoint
    error_message = "api_server_authorized_ip_ranges must list at least one CIDR, or set allow_public_api_endpoint = true to leave the public API endpoint open to any address."
  }
}

variable "cluster_admin_principal_ids" {
  type        = list(string)
  description = "Object IDs of extra Entra users, groups or service principals granted Azure Kubernetes Service RBAC Cluster Admin. The identity running Terraform always gets it."
  default     = []
}

variable "database" {
  type = object({
    sku_name   = optional(string, "B_Standard_B1ms")
    storage_mb = optional(number, 32768)
    version    = optional(string, "17")
  })
  description = "Azure Database for PostgreSQL flexible server (private, in a delegated subnet). The default is the burstable B1ms size: fine for a trial, move to a General Purpose sku (for example GP_Standard_D2s_v3) for production."
  default     = {}
}

variable "dns_service_ip" {
  type        = string
  description = "Cluster DNS service IP; must be inside service_cidr."
  default     = "10.100.0.10"
}

variable "enable_oauth" {
  type        = bool
  description = "Put oauth2-proxy (Microsoft Entra ID) in front of Flyte. Null follows exposure: on for public, off for tailscale."
  default     = null

  validation {
    # A public endpoint is never unauthenticated.
    condition     = !(var.exposure == "public" && var.enable_oauth == false)
    error_message = "enable_oauth cannot be false when exposure is public: a public endpoint is always behind OAuth."
  }
}

variable "enable_tailscale" {
  type        = bool
  description = "Install the Tailscale Kubernetes operator (the helm root does, reading this from the infra state). Required when exposure is tailscale."
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
    enabled         = optional(bool, false)
    vm_size         = optional(string, "Standard_NC4as_T4_v3")
    os_disk_size_gb = optional(number, 200)
    max_nodes       = optional(number, 4)
  })
  description = "Optional GPU pool for task pods, tainted nvidia.com/gpu=true:NoSchedule and labelled node-pool=gpu; scales from zero."
  default     = {}
}

variable "kubernetes_version" {
  type        = string
  description = "AKS Kubernetes minor version; one of the three most recent minors AKS supports in your region (check `az aks get-versions`)."
  default     = "1.34"
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Resource ID of an existing Log Analytics workspace that Container Insights already ships to. Null creates one named after var.name."
  default     = null
}

variable "name" {
  type        = string
  description = "Prefix for every resource name: 4-54 characters, lowercase letters, digits and single hyphens, starting with a letter and not ending in a hyphen."
  default     = "flyte"

  validation {
    # The tightest limits among the names built from it, in either repository: the Log Analytics workspace (the name
    # itself) needs at least 4 characters; the AKS DNS prefix (the name itself) allows at most 54; the blob
    # containers (<name>-data, <name>-metadata) and the Postgres server (<name>-<8-character suffix>) allow at most
    # 63, and containers reject two hyphens in a row.
    condition     = length(var.name) >= 4 && length(var.name) <= 54 && can(regex("^[a-z]([a-z0-9]*(-[a-z0-9]+)*)?$", var.name))
    error_message = "name must be 4-54 characters: lowercase letters, digits and single hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "nodes_cidr" {
  type        = string
  description = "Private subnet for AKS nodes. With Azure CNI overlay only nodes consume subnet addresses; pods use pod_cidr."
  default     = "10.0.0.0/18"
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

variable "pod_cidr" {
  type        = string
  description = "Overlay pod CIDR. Pod-IP exhaustion is the most common scale blocker and cannot be resized in place, so keep it large."
  default     = "10.244.0.0/16"
}

variable "postgres_subnet_cidr" {
  type        = string
  description = "Subnet delegated to the Postgres flexible server. Must lie inside address_space and not overlap nodes_cidr."
  default     = "10.0.64.0/24"
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

variable "region" {
  type        = string
  description = "Azure location for all resources (for example the output of `az account list-locations`). No default: this repository hard-codes no region."
}

variable "service_cidr" {
  type        = string
  description = "Kubernetes service CIDR; must not overlap the VNet or pod CIDR."
  default     = "10.100.0.0/16"
}

variable "system_node_pool" {
  type = object({
    vm_size         = optional(string, "Standard_D4s_v5")
    node_count      = optional(number, 3)
    os_disk_size_gb = optional(number, 200)
  })
  description = "System pool: fixed size, not burstable (at least 4 vCPU / 16 GB), untainted so task pods can use it. The image builder needs 50 GiB of ephemeral storage, hence the 200 GiB OS disk."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Extra tags, merged over the defaults (managed-by, stack)."
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
  description = "Tailscale add-on settings. Used only when enable_tailscale is true. tailnet is the MagicDNS name without its domain suffix (for example tail1234); it is required when exposure is tailscale."
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

variable "worker_node_pool" {
  type = object({
    enabled         = optional(bool, true)
    vm_size         = optional(string, "Standard_D8as_v5")
    os_disk_size_gb = optional(number, 200)
    max_nodes       = optional(number, 10)
  })
  description = "Dedicated CPU worker pool (labelled union.ai/node-role=worker); scales from zero. When disabled, task pods run on the system pool."
  default     = {}
}
