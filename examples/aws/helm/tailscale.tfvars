# Goes with ../infra/tailscale.tfvars: everything about the cluster and the tailnet comes from that root's state.
# Set the Tailscale client secret with TF_VAR_tailscale_oauth_client_secret, never in a file.
enable_mcp = true
