# variable "exposure" and variable "enable_oauth" are declared and validated in variables.tf, not here.
# How the Flyte endpoint is reached (CONVENTIONS section 6). The front door itself is in the helm root's exposure.tf;
# this root resolves the mode and the URL, because the Entra redirect URIs (oauth.tf) need the URL.

locals {
  public = var.exposure == "public"

  # A public endpoint is always behind OAuth; on the tailnet it is opt-in.
  oauth = local.public || coalesce(var.enable_oauth, false)

  # MagicDNS name of the tailnet.
  tailnet_domain = var.tailscale.tailnet == null ? null : "${var.tailscale.tailnet}.ts.net"

  # Where users reach Flyte.
  flyte_url = local.public ? "https://${var.public.hostname}" : "https://${var.tailscale.flyte_hostname}.${local.tailnet_domain}"
}
