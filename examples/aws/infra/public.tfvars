# Public endpoint behind Amazon Cognito and oauth2-proxy. After the helm apply, point a DNS record for the hostname at
# its load_balancer_address output and create Cognito users (README).
name   = "acme-flyte"
region = "us-east-2"

exposure = "public"

public = {
  hostname   = "flyte.example.com"
  acme_email = "admin@example.com"
}

oauth = {
  allowed_email_domains = ["example.com"]
}

cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["192.0.2.10/32"]
