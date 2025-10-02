output "main_instance_public_ip" {
  description = "Public IP of the main Dokploy instance"
  value       = oci_core_instance.dokploy_main.public_ip
}

output "main_instance_id" {
  description = "OCID of the main Dokploy instance"
  value       = oci_core_instance.dokploy_main.id
}

output "worker_instance_public_ips" {
  description = "Public IPs of the worker instances"
  value       = oci_core_instance.dokploy_worker[*].public_ip
}

output "worker_instance_ids" {
  description = "OCIDs of the worker instances"
  value       = oci_core_instance.dokploy_worker[*].id
}

output "dokploy_dashboard_url" {
  description = "URL to access the Dokploy dashboard"
  value       = "http://${oci_core_instance.dokploy_main.public_ip}:3000"
}
