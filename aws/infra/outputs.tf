output "account_id" {
  description = "AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}

output "backend_role_arn" {
  description = "IRSA role ARN of the flyte-binary backend service account."
  value       = aws_iam_role.workload["backend"].arn
}

output "bucket_name" {
  description = "Name of the S3 bucket holding Flyte's data."
  value       = aws_s3_bucket.this.bucket
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority of the EKS cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "database_host" {
  description = "Hostname of the RDS instance holding Flyte's database. Reachable only from inside the VPC."
  value       = aws_db_instance.this.address
}

output "database_name" {
  description = "Name of Flyte's database."
  value       = local.database_name
}

output "database_password" {
  description = "Password of the database user. The helm root passes it to the chart."
  value       = random_password.database.result
  sensitive   = true
}

output "database_username" {
  description = "Database user Flyte connects as."
  value       = local.database_username
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
      # Behind OAuth the SDK discovers the Cognito sign-in and client from Flyte's auth metadata and signs in through
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
  description = "The gpu_node_pool input, for the helm root (it installs the NVIDIA device plugin when the pool is enabled)."
  value       = var.gpu_node_pool
}

output "gpu_node_selector" {
  description = "Node labels that select the GPU pool's nodes, for the helm root (the NVIDIA device plugin's nodeSelector)."
  value       = local.gpu_node_selector
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "oauth" {
  description = "The oauth input (who may sign in), for the helm root."
  value       = var.oauth
}

output "oauth_callback_url" {
  description = "OAuth callback URL registered with the identity provider; null when OAuth is off."
  value       = local.oauth ? "${local.flyte_url}/oauth2/callback" : null
}

output "oauth_cli_client_id" {
  description = "Cognito app client of the flyte CLI and SDK (public, PKCE); null when OAuth is off."
  value       = local.oauth ? aws_cognito_user_pool_client.cli[0].id : null
}

output "oauth_cli_redirect_uri" {
  description = "Redirect URI registered for the CLI client, where the SDK listens during sign-in; null when OAuth is off."
  value       = local.oauth ? local.cli_redirect_uri : null
}

output "oauth_client_id" {
  description = "Cognito app client oauth2-proxy signs browser users in with; null when OAuth is off."
  value       = local.oauth ? aws_cognito_user_pool_client.proxy[0].id : null
}

output "oauth_client_secret" {
  description = "Secret of the oauth2-proxy app client; null when OAuth is off. The helm root passes it to oauth2-proxy."
  value       = local.oauth ? aws_cognito_user_pool_client.proxy[0].client_secret : null
  sensitive   = true
}

output "oauth_enabled" {
  description = "Whether OAuth is on: always for public, enable_oauth on the tailnet."
  value       = local.oauth
}

output "oauth_issuer_url" {
  description = "OIDC issuer of the Cognito user pool; null when OAuth is off."
  value       = local.cognito_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for the cluster."
  value       = module.eks.oidc_provider_arn
}

output "public" {
  description = "The public input (hostname and ACME contact), for the helm root."
  value       = var.public
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "service_accounts" {
  description = "Namespace and name of each Kubernetes service account an IRSA role trusts (backend, task). The helm root creates them under these names."
  value       = local.service_accounts
}

output "tailnet_domain" {
  description = "MagicDNS domain of the tailnet; null when tailscale.tailnet is not set."
  value       = local.tailnet_domain
}

output "tailscale" {
  description = "The tailscale input, for the helm root."
  value       = var.tailscale
}

output "task_role_arn" {
  description = "IRSA role ARN of the task pods' service account."
  value       = aws_iam_role.workload["task"].arn
}
