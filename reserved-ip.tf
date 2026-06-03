# Get VNIC attachments for main instance (only while deployed)
data "oci_core_vnic_attachments" "dokploy_main_vnic_attachments" {
  count          = var.deploy ? 1 : 0
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.dokploy_main[0].id
}

# Get the primary VNIC details
data "oci_core_vnic" "dokploy_main_vnic" {
  count   = var.deploy ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.dokploy_main_vnic_attachments[0].vnic_attachments[0].vnic_id
}

# Get the private IPs for the VNIC
data "oci_core_private_ips" "dokploy_main_private_ips" {
  count   = var.deploy ? 1 : 0
  vnic_id = data.oci_core_vnic.dokploy_main_vnic[0].id
}

# Reserved Public IP for main instance.
# The resource itself is ALWAYS present (never destroyed by the deploy toggle):
# when deploy = true it is assigned to the main node's private IP; when
# deploy = false private_ip_id is null, so the IP (170.9.237.30) stays RESERVED
# but unassigned and is re-attached on the next deploy = true apply.
resource "oci_core_public_ip" "dokploy_main_reserved_ip" {
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  private_ip_id  = var.deploy ? data.oci_core_private_ips.dokploy_main_private_ips[0].private_ips[0].id : null
  display_name   = "dokploy-main-ip-${random_string.resource_code.result}"

  lifecycle {
    prevent_destroy = true
  }
}
