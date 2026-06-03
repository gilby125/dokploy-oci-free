# Look up Cloudflare zone IDs by domain name
data "cloudflare_zone" "domains" {
  for_each = toset([for record in var.managed_dns_records : record.domain])

  name = each.value
}

# Cloudflare DNS records for Dokploy endpoints
resource "cloudflare_record" "dokploy_a" {
  for_each = var.managed_dns_records

  zone_id         = data.cloudflare_zone.domains[each.value.domain].id
  name            = each.value.subdomain
  type            = "A"
  content         = oci_core_public_ip.dokploy_main_reserved_ip.ip_address
  ttl             = 1 # Auto
  proxied         = var.cloudflare_proxied
  allow_overwrite = true
}

# --- agentplane public front door --------------------------------------------
# doppelops.com apex = the fleet; each app is a <app>.doppelops.com subdomain.
# agentplane.doppelops.com points at the Flexible NLB public IP and is
# Cloudflare-proxied (orange cloud) so CF fronts TLS/CDN; per-node Caddy holds
# the CF Origin cert (Full-Strict). Gated on deploy (NLB only exists then).
data "cloudflare_zone" "doppelops" {
  count = var.deploy ? 1 : 0
  name  = var.doppelops_zone
}

resource "cloudflare_record" "agentplane" {
  count = var.deploy ? 1 : 0

  zone_id         = data.cloudflare_zone.doppelops[0].id
  name            = var.agentplane_subdomain
  type            = "A"
  content         = one([for ip in oci_network_load_balancer_network_load_balancer.agentplane[0].ip_addresses : ip.ip_address if ip.is_public])
  ttl             = 1 # Auto
  proxied         = true
  allow_overwrite = true
}
