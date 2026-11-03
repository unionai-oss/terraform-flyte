# Tailnet-only access without OAuth (helm/tailscale.tfvars adds the MCP server). tailnet is your MagicDNS name without
# its domain suffix.
name   = "acme-flyte"
region = "eastus2"

exposure         = "tailscale"
enable_tailscale = true

tailscale = {
  tailnet         = "tail1234"
  oauth_client_id = "example-client-id"
}

# The AKS API endpoint is public (nodes are private); limit it to the address you run Terraform from.
api_server_authorized_ip_ranges = ["192.0.2.10/32"]
