output "dokploy_dashboard" {
  value = "https://${oci_core_public_ip.dokploy_main_reserved_ip.ip_address} (wait 3-5 minutes to finish Dokploy installation)"
}

output "dokploy_worker_ips" {
  value = [for instance in oci_core_instance.dokploy_worker : "${instance.public_ip} (use it to add the server in Dokploy Dashboard)"]
}
