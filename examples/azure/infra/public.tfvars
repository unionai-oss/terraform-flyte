# Public endpoint behind Microsoft Entra ID and oauth2-proxy. After apply, point a DNS record for the hostname at
# the load_balancer_address output; users are the Entra users whose sign-in name (UPN) matches oauth.
name   = "acme-flyte"
region = "eastus2"

exposure = "public"

public = {
  hostname   = "flyte.example.com"
  acme_email = "admin@example.com"
}

oauth = {
  allowed_email_domains = ["example.com"]
}

# The AKS API endpoint is public (nodes are private); limit it to your own address.
api_server_authorized_ip_ranges = ["192.0.2.10/32"]
