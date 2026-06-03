# VCN configuration
resource "oci_core_vcn" "dokploy_vcn" {
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_id
  display_name   = "network-dokploy-${random_string.resource_code.result}"
  dns_label      = "vcn${random_string.resource_code.result}"
}

# Subnet configuration
resource "oci_core_subnet" "dokploy_subnet" {
  cidr_block     = "10.0.0.0/24"
  compartment_id = var.compartment_id
  display_name   = "subnet-dokploy-${random_string.resource_code.result}"
  dns_label      = "subnet${random_string.resource_code.result}"
  route_table_id = oci_core_vcn.dokploy_vcn.default_route_table_id
  vcn_id         = oci_core_vcn.dokploy_vcn.id

  # Attach the security list
  security_list_ids = [oci_core_security_list.dokploy_security_list.id]
}

# Internet Gateway configuration
resource "oci_core_internet_gateway" "dokploy_internet_gateway" {
  compartment_id = var.compartment_id
  display_name   = "Internet Gateway network-dokploy"
  enabled        = true
  vcn_id         = oci_core_vcn.dokploy_vcn.id
}

# Default Route Table
resource "oci_core_default_route_table" "dokploy_default_route_table" {
  manage_default_resource_id = oci_core_vcn.dokploy_vcn.default_route_table_id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.dokploy_internet_gateway.id
  }
}

# Security List for Dokploy
resource "oci_core_security_list" "dokploy_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dokploy_vcn.id
  display_name   = "Dokploy Security List"

  # SSH - restricted to current IP, whitelisted IPs, and internal VCN
  dynamic "ingress_security_rules" {
    for_each = concat([local.current_ip_cidr], var.admin_ip_whitelist, [oci_core_vcn.dokploy_vcn.cidr_block])
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value
      tcp_options {
        min = 22
        max = 22
      }
      description = "Allow SSH from whitelisted IP: ${ingress_security_rules.value}"
    }
  }

  # Dokploy Dashboard - only reachable from inside the VCN; external access must use Traefik HTTPS
  ingress_security_rules {
    protocol = "6" # TCP
    source   = oci_core_vcn.dokploy_vcn.cidr_block
    tcp_options {
      min = 3000
      max = 3000
    }
    description = "Allow Dokploy dashboard from within the VCN"
  }

  # AdGuard Home Web UI - restricted to current IP, whitelisted IPs, and internal VCN
  dynamic "ingress_security_rules" {
    for_each = concat([local.current_ip_cidr], var.admin_ip_whitelist, [oci_core_vcn.dokploy_vcn.cidr_block])
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value
      tcp_options {
        min = 3053
        max = 3053
      }
      description = "Allow AdGuard Home web UI from whitelisted IP: ${ingress_security_rules.value}"
    }
  }

  # Komodo Periphery: the local Komodo Core reaches each node's agent on :8120.
  # Scoped to the admin whitelist (which includes the IP Terraform is run from,
  # i.e. the Core's egress) so the agent is not exposed to the internet.
  dynamic "ingress_security_rules" {
    for_each = concat([local.current_ip_cidr], var.admin_ip_whitelist, [oci_core_vcn.dokploy_vcn.cidr_block])
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value
      tcp_options {
        min = 8120
        max = 8120
      }
      description = "Allow Komodo Periphery from whitelisted IP: ${ingress_security_rules.value}"
    }
  }

  # DNS-over-TLS (AdGuard Home)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 853
      max = 853
    }
    description = "Allow DNS-over-TLS (DoT) traffic on port 853"
  }

  # HTTP & HTTPS traffic - public access
  # Service-level restrictions applied via Traefik IP whitelist middleware
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
    description = "Allow HTTP from internet (Traefik handles service-level restrictions)"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
    description = "Allow HTTPS from internet (Traefik handles service-level restrictions)"
  }

  # Docker Swarm manager coordination traffic (internal only)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = oci_core_vcn.dokploy_vcn.cidr_block
    tcp_options {
      min = 2377
      max = 2377
    }
    description = "Allow Docker Swarm manager traffic within VCN"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = oci_core_vcn.dokploy_vcn.cidr_block
    tcp_options {
      min = 7946
      max = 7946
    }
    description = "Allow Docker Swarm TCP gossip within VCN"
  }

  ingress_security_rules {
    protocol = "17" # UDP
    source   = oci_core_vcn.dokploy_vcn.cidr_block
    udp_options {
      min = 7946
      max = 7946
    }
    description = "Allow Docker Swarm UDP gossip within VCN"
  }

  ingress_security_rules {
    protocol = "17" # UDP
    source   = oci_core_vcn.dokploy_vcn.cidr_block
    udp_options {
      min = 4789
      max = 4789
    }
    description = "Allow Docker Swarm overlay network within VCN"
  }

  # ICMP traffic
  ingress_security_rules {
    description = "ICMP traffic for 3, 4"
    icmp_options {
      code = "4"
      type = "3"
    }
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
  }

  ingress_security_rules {
    description = "ICMP traffic for 3"
    icmp_options {
      code = "-1"
      type = "3"
    }
    protocol    = "1"
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    stateless   = "false"
  }

  # Traefik Proxy
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 81
      max = 81
    }
    description = "Allow Traefik HTTP traffic on port 81"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 444
      max = 444
    }
    description = "Allow Traefik HTTPS traffic on port 444"
  }


  # Allow all traffic within VCN for Docker Swarm inter-node communication
  ingress_security_rules {
    protocol    = "all"
    source      = "10.0.0.0/16"
    description = "Allow all traffic within VCN for Docker Swarm"
  }

  # Egress Rule (optional, if needed)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "Allow all egress traffic"
  }
}
