# Object Storage for Docker/Dokploy data backups
# Free tier includes 20 GB total object storage (10 GB Standard + 10 GB Archive)

# Create object storage bucket for backups
resource "oci_objectstorage_bucket" "dokploy_backups" {
  compartment_id = var.compartment_id
  name           = "dokploy-backups-${random_string.resource_code.result}"
  namespace      = data.oci_objectstorage_namespace.current.namespace

  access_type           = "NoPublicAccess"
  storage_tier          = "Standard"
  object_events_enabled = false
  versioning            = "Enabled" # Keep multiple versions for safety

  # Note: Retention rules cannot be used with versioning enabled
  # Cleanup will be handled by the backup script (keeps last N backups locally)

  lifecycle {
    prevent_destroy = false # Set to true after first backup
  }
}

# Get the object storage namespace for the tenancy
data "oci_objectstorage_namespace" "current" {
  compartment_id = var.compartment_id
}
