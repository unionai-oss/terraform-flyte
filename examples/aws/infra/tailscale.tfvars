# Tailnet-only access without OAuth (the MCP server is turned on in ../helm/tailscale.tfvars). tailnet is your
# MagicDNS name without its domain suffix. The operator's client secret is a helm input
# (TF_VAR_tailscale_oauth_client_secret), never in a file.
name   = "acme-flyte"
region = "us-east-2"

exposure         = "tailscale"
enable_tailscale = true

tailscale = {
  tailnet         = "tail1234"
  oauth_client_id = "example-client-id"
}

# The cluster endpoint is private by default: the helm apply needs a route to it, so run that from a host inside the
# VPC, or open it to your own address.
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
