# Flexible Network Load Balancer (L4) — public front door for agentplane.
#
# Path: Cloudflare (proxied, TLS) -> this NLB (L4 passthrough, public IP)
#       -> TLS-terminating proxy (Caddy w/ Cloudflare Origin cert) on each node :443
#       -> agentplane `serve --public` :8080
#
# The Flexible Network Load Balancer is Always Free (1 instance, no bandwidth
# cap, no per-byte charge) — unlike the L7 "Load Balancer" (free only at 10 Mbps).
# Being L4, it cannot terminate TLS; the per-node proxy does (CF SSL = Full-strict).

variable "num_web_backends" {
  description = "How many OCI nodes serve the public agentplane web tier behind the NLB. Free tier is now 2 nodes (main = web, worker-3 = Postgres only), so only main serves the web tier -> 1. The pool is taken from all_node_private_ips with main first, so a value of 1 means just main; do NOT raise to 2 unless a worker actually runs the Caddy/web tier (worker-3 does not)."
  type        = number
  default     = 1
}

variable "web_backend_port" {
  description = "Port on each node the NLB forwards to — the TLS-terminating proxy (Caddy/Traefik with the Cloudflare Origin cert), which proxies to agentplane web :8080."
  type        = number
  default     = 443
}

locals {
  # Every OCI node runs Periphery + the web tier; take the first N node private
  # IPs as the public backend pool. (Komodo Core lives off-box on the LAN, so no
  # OCI node has a special control role here.)
  all_node_private_ips = var.deploy ? concat(
    [oci_core_instance.dokploy_main[0].private_ip],
    [for w in oci_core_instance.dokploy_worker : w.private_ip],
  ) : []
  web_backend_ips = slice(
    local.all_node_private_ips,
    0,
    min(var.num_web_backends, length(local.all_node_private_ips)),
  )
}

resource "oci_network_load_balancer_network_load_balancer" "agentplane" {
  count          = var.deploy ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "agentplane-nlb-${random_string.resource_code.result}"
  subnet_id      = oci_core_subnet.dokploy_subnet.id
  is_private     = false # public front door; reachable by Cloudflare's edge
}

resource "oci_network_load_balancer_backend_set" "web" {
  count                    = var.deploy ? 1 : 0
  name                     = "agentplane-web"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.agentplane[0].id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false # CF is the visible client anyway; real client via CF-Connecting-IP

  # TCP connect on the proxy port = node is serving. (Swap to an HTTPS checker
  # against /healthz once the Caddy proxy + Origin cert are in place if you want
  # app-level liveness rather than port liveness.)
  health_checker {
    protocol = "TCP"
    port     = var.web_backend_port
  }
}

resource "oci_network_load_balancer_backend" "web" {
  count                    = length(local.web_backend_ips)
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.agentplane[0].id
  backend_set_name         = oci_network_load_balancer_backend_set.web[0].name
  ip_address               = local.web_backend_ips[count.index]
  port                     = var.web_backend_port
}

resource "oci_network_load_balancer_listener" "https" {
  count                    = var.deploy ? 1 : 0
  name                     = "agentplane-https"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.agentplane[0].id
  default_backend_set_name = oci_network_load_balancer_backend_set.web[0].name
  protocol                 = "TCP" # L4 passthrough; TLS terminates on the node
  port                     = 443
}

output "agentplane_nlb_ip" {
  description = "Public IP of the agentplane Flexible Network Load Balancer. Point agentplane.doppelops.com here (proxied) in Cloudflare."
  value       = var.deploy ? [for ip in oci_network_load_balancer_network_load_balancer.agentplane[0].ip_addresses : ip.ip_address if ip.is_public] : []
}
