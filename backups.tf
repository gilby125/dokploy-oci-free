# Boot Volume Backup Policies for Dokploy
#
# Free-tier rule (verified against Oracle docs, 2026-07):
#   Always Free includes FIVE total volume backups (boot + block combined) in
#   the home region. The allowance is COUNT-based, not GB — size is irrelevant.
#   Stay at <= 5 concurrent backups and backup storage is $0.
#
# We back up two boot volumes daily with 2-day retention:
#   steady state   = 2 volumes x 2 days            = 4 backups  (free)
#   rotation peak  = staggered hours (03:00 / 05:00) so the two volumes never
#                    hit their transient 3rd-backup window at the same instant
#                    -> worst case 3 + 2                = 5 backups  (free)
# A hard $0 guarantee is impossible with symmetric 2-day retention on two
# volumes (simultaneous pruning lag could momentarily create a 6th ~1-2 GB
# incremental, billing sub-cent). To eliminate even that, drop main to 1-day
# retention, or back up only the DB node (worker-3).

# --- DB worker (worker-3) — the Postgres system-of-record --------------------
# Highest-value volume: holds irreplaceable data. Backed up at 03:00 UTC.
data "oci_core_boot_volume_attachments" "db_worker_boot_attachment" {
  count               = var.deploy ? 1 : 0
  availability_domain = local.worker_ad[var.db_worker_id]
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.dokploy_worker[var.db_worker_id].id
}

resource "oci_core_volume_backup_policy" "db_worker_backup_policy" {
  compartment_id = var.compartment_id
  display_name   = "dokploy-w3-daily-backup"

  schedules {
    backup_type       = "INCREMENTAL"
    period            = "ONE_DAY"
    retention_seconds = 172800 # 2 days (2 x 24 x 60 x 60)
    time_zone         = "UTC"
    hour_of_day       = 3 # 03:00 UTC
    offset_type       = "STRUCTURED"
    offset_seconds    = 0
  }
}

resource "oci_core_volume_backup_policy_assignment" "db_worker_boot_backup_assignment" {
  count     = var.deploy ? 1 : 0
  asset_id  = data.oci_core_boot_volume_attachments.db_worker_boot_attachment[0].boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.db_worker_backup_policy.id
}

# --- Main instance (Dokploy manager) -----------------------------------------
# Reproducible from Terraform, but backed up too per operator choice. Staggered
# to 05:00 UTC so its rotation peak never overlaps worker-3's, keeping the
# combined concurrent count at <= 5.
data "oci_core_boot_volume_attachments" "dokploy_main_boot_attachment" {
  count               = var.deploy ? 1 : 0
  availability_domain = var.availability_domain_main
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.dokploy_main[0].id
}

resource "oci_core_volume_backup_policy" "dokploy_main_backup_policy" {
  compartment_id = var.compartment_id
  display_name   = "dokploy-main-daily-backup"

  schedules {
    backup_type       = "INCREMENTAL"
    period            = "ONE_DAY"
    retention_seconds = 172800 # 2 days
    time_zone         = "UTC"
    hour_of_day       = 5 # 05:00 UTC — staggered from worker-3's 03:00
    offset_type       = "STRUCTURED"
    offset_seconds    = 0
  }
}

resource "oci_core_volume_backup_policy_assignment" "dokploy_main_boot_backup_assignment" {
  count     = var.deploy ? 1 : 0
  asset_id  = data.oci_core_boot_volume_attachments.dokploy_main_boot_attachment[0].boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.dokploy_main_backup_policy.id
}
