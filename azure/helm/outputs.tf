output "load_balancer_address" {
  description = "Hostname or IP of the load balancer to point your DNS record at (public mode); null otherwise or until the address is assigned."
  value = try(coalesce(
    data.kubernetes_service_v1.traefik[0].status[0].load_balancer[0].ingress[0].hostname,
    data.kubernetes_service_v1.traefik[0].status[0].load_balancer[0].ingress[0].ip,
  ), null)
}

output "mcp_url" {
  description = "URL of the Flyte MCP server (streamable HTTP); null when enable_mcp is false."
  value = !var.enable_mcp ? null : (
    local.infra.exposure == "tailscale" && !local.oauth ? "https://${local.infra.tailscale.mcp_hostname}.${local.infra.tailnet_domain}${local.mcp_path}/mcp" : "${local.infra.flyte_url}${local.mcp_path}/mcp"
  )
}
