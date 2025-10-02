# Get VNIC attachments for main instance
data "oci_core_vnic_attachments" "dokploy_main_vnic_attachments" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.dokploy_main.id
}

# Get the primary VNIC details
data "oci_core_vnic" "dokploy_main_vnic" {
  vnic_id = data.oci_core_vnic_attachments.dokploy_main_vnic_attachments.vnic_attachments[0].vnic_id
}

# Get the private IPs for the VNIC
data "oci_core_private_ips" "dokploy_main_private_ips" {
  vnic_id = data.oci_core_vnic.dokploy_main_vnic.id
}

# Reserved Public IP for main instance
resource "oci_core_public_ip" "dokploy_main_reserved_ip" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.dokploy_main_private_ips.private_ips[0].id
  display_name   = "dokploy-main-ip-${random_string.resource_code.result}"

  lifecycle {
    prevent_destroy = true
  }
}
