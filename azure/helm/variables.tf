variable "enable_mcp" {
  type        = bool
  description = "Run the Flyte MCP server (the SDK's flyte-mcp) in the cluster."
  default     = false
}

variable "infra_state" {
  type = object({
    backend = optional(string, "local")
    config  = optional(any)
  })
  description = "Where the infra root keeps its state: the backend type and its settings, the same as that root's backend block. The default is the local state of ../infra, which is what a first run with no backend configured uses."
  default     = {}
}

variable "mcp" {
  type = object({
    domain            = optional(string, "development")
    flyte_sdk_version = optional(string, "2.12.0")
    image             = optional(string, "ghcr.io/astral-sh/uv:0.9.30-python3.12-bookworm-slim@sha256:e5b65587bce7de595f299855d7385fe7fca39b8a74baa261ba1b7147afa78e58")
    project           = optional(string, "flytesnacks")
    read_only         = optional(bool, true)
  })
  description = "Flyte MCP server settings. Used only when enable_mcp is true. image must provide uv and Python 3.12; the server is installed with uv when the pod starts."
  default     = {}

  # The version is interpolated into a shell command in mcp.tf.
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+([a-z0-9.+-]*)$", var.mcp.flyte_sdk_version))
    error_message = "mcp.flyte_sdk_version must be a version such as 2.12.0 (digits, then letters, digits and . + - only)."
  }
}

variable "tailscale_oauth_client_secret" {
  type        = string
  description = "Secret of the Tailscale OAuth client the operator authenticates with. Required when the infra root has enable_tailscale = true; set it with TF_VAR_tailscale_oauth_client_secret. It lives here, not in the infra root, so it never reaches the infra state this root reads."
  default     = null
  sensitive   = true

  validation {
    condition     = !local.infra.enable_tailscale || var.tailscale_oauth_client_secret != null
    error_message = "tailscale_oauth_client_secret is required when the infra root has enable_tailscale = true."
  }
}
