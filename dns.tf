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
