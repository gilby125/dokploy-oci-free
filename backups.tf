# Boot Volume Backup Policy for Dokploy Main Instance
# Provides automated daily backups with 5-day retention (free tier limit)

# Get the boot volume ID for the main instance
data "oci_core_boot_volume_attachments" "dokploy_main_boot_attachment" {
  availability_domain = var.availability_domain_main
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.dokploy_main.id
}

# Boot volume backup policy - daily backups with 5-day retention
resource "oci_core_volume_backup_policy" "dokploy_main_backup_policy" {
  compartment_id = var.compartment_id
  display_name   = "dokploy-main-daily-backup"

  schedules {
    backup_type       = "INCREMENTAL"
    period            = "ONE_DAY"
    retention_seconds = 432000 # 5 days (5 × 24 × 60 × 60)
    time_zone         = "UTC"
    hour_of_day       = 3 # 3 AM UTC
    offset_type       = "STRUCTURED"
    offset_seconds    = 0
  }

  # Keep policy even if associated resources are destroyed
  lifecycle {
    prevent_destroy = false # Set to true after first apply
  }
}

# Attach backup policy to main instance boot volume
resource "oci_core_volume_backup_policy_assignment" "dokploy_main_boot_backup_assignment" {
  asset_id  = data.oci_core_boot_volume_attachments.dokploy_main_boot_attachment.boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.dokploy_main_backup_policy.id
}

# Optional: Manual backup trigger (create a backup on-demand)
# Uncomment to create an immediate backup
# resource "oci_core_boot_volume_backup" "dokploy_main_manual_backup" {
#   boot_volume_id = data.oci_core_boot_volume_attachments.dokploy_main_boot_attachment.boot_volume_attachments[0].boot_volume_id
#   display_name   = "dokploy-main-manual-backup-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
#   type           = "INCREMENTAL"
# }
