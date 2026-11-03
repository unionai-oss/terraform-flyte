# Follows infra/tailscale.tfvars, which turns on the Tailscale add-on: set the operator's OAuth client secret with
# TF_VAR_tailscale_oauth_client_secret, never in a file. The MCP server is a helm setting.
enable_mcp = true
