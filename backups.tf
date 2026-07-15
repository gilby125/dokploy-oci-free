# Boot Volume Backup Policy for Dokploy Main Instance
# Provides automated daily backups with 5-day retention (free tier limit)

# Get the boot volume ID for the main instance
data "oci_core_boot_volume_attachments" "dokploy_main_boot_attachment" {
  count               = var.deploy ? 1 : 0
  availability_domain = var.availability_domain_main
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.dokploy_main[0].id
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
  count     = var.deploy ? 1 : 0
  asset_id  = data.oci_core_boot_volume_attachments.dokploy_main_boot_attachment[0].boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.dokploy_main_backup_policy.id
}

# Optional: Manual backup trigger (create a backup on-demand)
# Uncomment to create an immediate backup
# resource "oci_core_boot_volume_backup" "dokploy_main_manual_backup" {
#   boot_volume_id = data.oci_core_boot_volume_attachments.dokploy_main_boot_attachment.boot_volume_attachments[0].boot_volume_id
#   display_name   = "dokploy-main-manual-backup-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
#   type           = "INCREMENTAL"
# }

# --- DB worker (worker-3) boot-volume backup -------------------------------
# The shared Postgres node holds the system-of-record data and had NO backup.
# Attach the same daily/5-day policy to its boot volume so the DB gets an
# automated, crash-consistent daily snapshot (Postgres recovers on restart).
# Note: main + w3 together exceed the 5 Always-Free volume backups, so a little
# block-backup storage may bill — accepted (data-loss protection > a few cents).
data "oci_core_boot_volume_attachments" "db_worker_boot_attachment" {
  count               = var.deploy ? 1 : 0
  availability_domain = local.worker_ad[var.db_worker_id]
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.dokploy_worker[var.db_worker_id].id
}

resource "oci_core_volume_backup_policy_assignment" "db_worker_boot_backup_assignment" {
  count     = var.deploy ? 1 : 0
  asset_id  = data.oci_core_boot_volume_attachments.db_worker_boot_attachment[0].boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.dokploy_main_backup_policy.id
}
