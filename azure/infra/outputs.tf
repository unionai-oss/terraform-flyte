# Every value the helm root reads is an output here, under one name (CONVENTIONS section 3): settings both roots need
# are passed through under the variable's own name, derived values get a noun. terraform_remote_state drops the
# sensitive mark, so the helm root wraps the sensitive ones in sensitive() itself.

output "backend_client_id" {
  description = "Client ID of the backend identity, which the Flyte backend's service account is annotated with."
  value       = azurerm_user_assigned_identity.backend.client_id
}

output "bucket_name" {
  description = "Name of the blob container holding Flyte's data."
  value       = azurerm_storage_container.this.name
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = module.aks.cluster_ca_certificate
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API server URL."
  value       = yamldecode(module.aks.kube_config).clusters[0].cluster.server
  sensitive   = true
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.name
}

output "database_host" {
  description = "Host name of the Postgres flexible server holding the Flyte database (port 5432). Resolves and is reachable only from inside the VNet."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  description = "Name of the Flyte database on the server."
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "database_password" {
  description = "Password of the database administrator, for the Flyte chart."
  value       = random_password.database.result
  sensitive   = true
}

output "database_username" {
  description = "Database administrator login Flyte connects as."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "enable_tailscale" {
  description = "The enable_tailscale input, for the helm root."
  value       = var.enable_tailscale
}

output "exposure" {
  description = "The exposure input, for the helm root."
  value       = var.exposure
}

output "flyte_config" {
  description = "Minimal config for the flyte CLI and SDK: save it as ~/.flyte/config.yaml or point FLYTECTL_CONFIG at it."
  value = yamlencode({
    admin = {
      endpoint = "dns:///${trimprefix(local.flyte_url, "https://")}"
      insecure = false
      # Behind OAuth the SDK discovers the Entra ID sign-in and client from Flyte's auth metadata and signs in through
      # the browser (PKCE); on the tailnet, Tailscale already vouches for you.
      authType = local.oauth ? "Pkce" : "Passthrough"
    }
  })
}

output "flyte_url" {
  description = "URL Flyte is served on."
  value       = local.flyte_url
}

output "gpu_node_pool" {
  description = "The gpu_node_pool input with its defaults applied, for the helm root (the device plugin follows enabled)."
  value       = var.gpu_node_pool
}

output "gpu_node_selector" {
  description = "Node labels that select the GPU pool's nodes, for the helm root (the NVIDIA device plugin's nodeSelector)."
  value       = local.gpu_node_selector
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for the cluster. Entra ID sign-in needs kubelogin on PATH."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${module.aks.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "kubelogin_server_id" {
  description = "Entra server application of the cluster, the --server-id the helm root passes to kubelogin get-token."
  # From module.aks.kube_config, which is sensitive.
  value     = local.kubelogin_server_id
  sensitive = true
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace holding persisted task logs."
  value       = local.log_analytics_workspace_id
}

output "nat_gateway_public_ip" {
  description = "Static egress IP of the node subnet; use it to allowlist the cluster."
  value       = data.azurerm_public_ip.nat.ip_address
}

output "oauth" {
  description = "The oauth input (who may sign in), for the helm root's oauth2-proxy."
  value       = var.oauth
}

output "oauth_callback_url" {
  description = "OAuth callback URL registered with the identity provider; null when OAuth is off."
  value       = local.oauth ? "${local.flyte_url}/oauth2/callback" : null
}

output "oauth_cli_client_id" {
  description = "Client ID the flyte CLI and SDK sign in with (PKCE, no secret); null when OAuth is off. On Azure it is the one app registration, so the same as oauth_client_id."
  value       = one(azuread_application.this[*].client_id)
}

output "oauth_cli_redirect_uri" {
  description = "Redirect URI of the CLI's public-client platform, which Flyte advertises to the SDK; null when OAuth is off."
  value       = local.oauth ? local.cli_redirect_uri : null
}

output "oauth_client_id" {
  description = "Client ID oauth2-proxy signs in with; null when OAuth is off."
  value       = one(azuread_application.this[*].client_id)
}

output "oauth_enabled" {
  description = "Whether oauth2-proxy is in front of Flyte: enable_oauth resolved against exposure."
  value       = local.oauth
}

output "oauth_issuer_url" {
  description = "OIDC issuer of the app registration (the tenant's Entra v2.0 endpoint); null when OAuth is off."
  value       = local.oauth ? local.entra_issuer_url : null
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL used by the federated credentials."
  value       = module.aks.oidc_issuer_profile_issuer_url
}

output "public" {
  description = "The public input (hostname and ACME contact), for the helm root."
  value       = var.public
}

output "region" {
  description = "Azure location."
  value       = azurerm_resource_group.this.location
}

output "resource_group_name" {
  description = "Resource group holding all resources."
  value       = azurerm_resource_group.this.name
}

output "service_accounts" {
  description = "Namespace and name of each Kubernetes service account an identity here trusts (backend, task, oauth2_proxy). The helm root creates or names exactly these."
  value = merge(local.service_accounts, {
    oauth2_proxy = { namespace = local.oauth2_proxy_namespace, name = local.oauth2_proxy_service_account }
  })
}

output "storage_account_name" {
  description = "Storage account name."
  value       = azurerm_storage_account.this.name
}

output "tailnet_domain" {
  description = "MagicDNS domain of the tailnet (tailscale.tailnet plus the Tailscale suffix); null without tailscale.tailnet."
  value       = local.tailnet_domain
}

output "tailscale" {
  description = "The tailscale input with its defaults applied, for the helm root."
  value       = var.tailscale
}

output "task_client_id" {
  description = "Client ID of the task identity, which the task pods' service account is annotated with."
  value       = azurerm_user_assigned_identity.task.client_id
}
