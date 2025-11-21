# Dokploy Recovery Procedures

This document describes how to recover your Dokploy instance if Terraform recreates it or if data is lost.

## Backup Strategy Overview

Your infrastructure has **three layers** of backup protection:

0. **Dokploy Application Backups** (Your existing S3 backups)
   - Application-level backups managed by Dokploy
   - Backs up databases and application data
   - **Use this for:** Recovering individual apps/databases

1. **Boot Volume Backups** (Infrastructure layer - Automated via OCI)
   - Runs daily at 3 AM UTC
   - Incremental backups
   - 5-day retention (free tier limit)
   - Captures entire OS, Docker, and Dokploy data
   - **Use this for:** Full disaster recovery when instance is destroyed

2. **Object Storage Backups** (Docker layer - Automated via systemd timer)
   - Runs daily at 2 AM UTC
   - Backs up `/var/lib/docker/volumes` and `/var/lib/dokploy`
   - 7-day retention (configurable)
   - Stored in OCI Object Storage bucket
   - **Use this for:** Recovering Docker state and Dokploy configuration

## Which Backup Should I Use?

| Scenario | Recommended Backup | Why |
|----------|-------------------|-----|
| Single app/database issue | Dokploy S3 backup | Fastest, app-specific |
| Terraform recreated instance | Boot Volume backup | Full system restore |
| Docker Swarm cluster broke | Object Storage backup | Restores all containers/volumes |
| Need to migrate to new instance | Object Storage + Dokploy S3 | Clean migration path |

## Infrastructure Backup Mechanisms

Your infrastructure has two automated backup mechanisms:

1. **Boot Volume Backups** (Automated via OCI)
   - Runs daily at 3 AM UTC
   - Incremental backups
   - 5-day retention (free tier limit)
   - Captures entire OS, Docker, and Dokploy data

2. **Object Storage Backups** (Automated via systemd timer)
   - Runs daily at 2 AM UTC
   - Backs up `/var/lib/docker/volumes` and `/var/lib/dokploy`
   - 7-day retention (configurable)
   - Stored in OCI Object Storage bucket

## Recovery Scenarios

### Scenario 1: Terraform Recreated the Instance

**What happened:** Instance was destroyed and recreated, all data lost.

**Recovery Steps:**

#### Option A: Restore from Boot Volume Backup (Recommended - Full System)

**Method 1: Using Recovery Variable (Easiest)**

1. **Find the preserved boot volume or backup:**
   ```bash
   # List preserved boot volumes
   oci bv boot-volume list \
     --compartment-id <your-compartment-id> \
     --sort-by TIMECREATED \
     --sort-order DESC

   # Or list boot volume backups
   oci bv boot-volume-backup list \
     --compartment-id <your-compartment-id> \
     --sort-by TIMECREATED \
     --sort-order DESC
   ```

2. **Get the boot volume OCID** from the output (look for most recent)

3. **Set the recovery variable:**

   Add to `terraform.tfvars`:
   ```hcl
   recovery_boot_volume_id = "ocid1.bootvolume.oc1.region.abc123..."
   ```

4. **Destroy and recreate the instance:**
   ```bash
   terraform destroy -target=oci_core_instance.dokploy_main
   terraform apply
   ```

5. **Remove the recovery variable** from `terraform.tfvars` (or set to empty string) and apply again:
   ```bash
   terraform apply
   ```
   This ensures future applies use the standard image source.

6. **Verify everything is working:**
   ```bash
   ssh ubuntu@<instance-ip>
   docker ps
   systemctl status dokploy-backup.timer
   ```

**Method 2: Manual Edit (Legacy)**

1. **Find the latest backup:**
   ```bash
   oci bv boot-volume-backup list \
     --compartment-id <your-compartment-id> \
     --sort-by TIMECREATED \
     --sort-order DESC
   ```

2. **Get the backup OCID** from the output (look for most recent)

3. **Destroy the new (empty) instance:**
   ```bash
   terraform destroy -target=oci_core_instance.dokploy_main
   ```

4. **Create new instance from backup:**

   Edit `main.tf` temporarily (change the conditional):
   ```hcl
   source_details {
     source_id   = "ocid1.bootvolumebackup.oc1..." # Your backup OCID
     source_type = "bootVolumeBackup"              # Use "bootVolume" for preserved volumes
   }
   ```

5. **Apply Terraform:**
   ```bash
   terraform apply
   ```

6. **Revert `main.tf` back to conditional logic** and commit

7. **Verify everything is working:**
   ```bash
   ssh ubuntu@<instance-ip>
   docker ps
   systemctl status dokploy-backup.timer
   ```

#### Option B: Restore from Object Storage Backup (Selective - Docker/Dokploy Only)

1. **SSH into the new instance:**
   ```bash
   ssh ubuntu@<instance-ip>
   ```

2. **List available backups:**
   ```bash
   oci os object list \
     --bucket-name <backup-bucket-name> \
     --namespace <namespace>
   ```

3. **Download the latest backups:**
   ```bash
   # Create restore directory
   sudo mkdir -p /var/restore
   cd /var/restore

   # Download Docker volumes backup
   oci os object get \
     --bucket-name <backup-bucket> \
     --namespace <namespace> \
     --name dokploy-backup-YYYYMMDD-HHMMSS-docker-volumes.tar.gz \
     --file docker-volumes.tar.gz

   # Download Dokploy data backup
   oci os object get \
     --bucket-name <backup-bucket> \
     --namespace <namespace> \
     --name dokploy-backup-YYYYMMDD-HHMMSS-dokploy-data.tar.gz \
     --file dokploy-data.tar.gz
   ```

4. **Stop Docker and Dokploy:**
   ```bash
   sudo systemctl stop docker
   ```

5. **Restore the data:**
   ```bash
   # Backup current (empty) state just in case
   sudo mv /var/lib/docker /var/lib/docker.empty
   sudo mv /var/lib/dokploy /var/lib/dokploy.empty

   # Extract backups
   sudo tar -xzf docker-volumes.tar.gz -C /var/lib/
   sudo tar -xzf dokploy-data.tar.gz -C /var/lib/

   # Fix permissions
   sudo chown -R root:root /var/lib/docker
   sudo chown -R root:root /var/lib/dokploy
   ```

6. **Restart Docker:**
   ```bash
   sudo systemctl start docker
   ```

7. **Verify containers are running:**
   ```bash
   docker ps
   docker service ls  # If using Swarm
   ```

### Scenario 2: Manual Backup Before Risky Operation

**Before running `terraform apply` that might recreate instances:**

1. **Trigger manual backup:**
   ```bash
   ssh ubuntu@<instance-ip>
   sudo /usr/local/bin/dokploy-backup.sh
   ```

2. **Verify backup succeeded:**
   ```bash
   # Check logs
   sudo journalctl -u dokploy-backup.service -n 50

   # Verify in object storage
   oci os object list --bucket-name <bucket> --namespace <namespace>
   ```

3. **Proceed with Terraform changes**

### Scenario 3: Accidental Data Loss (Deleted Containers/Volumes)

**Recovery Steps:**

1. **SSH into instance:**
   ```bash
   ssh ubuntu@<instance-ip>
   ```

2. **Stop Docker temporarily:**
   ```bash
   sudo systemctl stop docker
   ```

3. **Follow "Option B" steps above** to restore from object storage

## Monitoring Backups

### Check Boot Volume Backup Status

```bash
# List recent backups
oci bv boot-volume-backup list \
  --compartment-id <compartment-id> \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --limit 10

# Check backup policy
oci bv volume-backup-policy get \
  --policy-id <policy-id>
```

### Check Object Storage Backup Status

```bash
# Via OCI CLI
oci os object list \
  --bucket-name <bucket-name> \
  --namespace <namespace>

# On the instance (check timer)
ssh ubuntu@<instance-ip>
systemctl status dokploy-backup.timer
systemctl list-timers dokploy-backup.timer

# View recent backup logs
journalctl -u dokploy-backup.service --since "24 hours ago"
```

### Verify Automated Backups Are Running

```bash
ssh ubuntu@<instance-ip>

# Check timer is active
systemctl is-active dokploy-backup.timer

# See next scheduled run
systemctl list-timers dokploy-backup.timer

# Check recent runs
journalctl -u dokploy-backup.service -n 100
```

## Backup Configuration

### Adjust Object Storage Backup Retention

Edit `terraform.tfvars`:
```hcl
backup_retention_days = 14  # Change from default 7 days
```

Then apply:
```bash
terraform apply
```

### Disable Automated Backups

Edit `terraform.tfvars`:
```hcl
enable_automated_backups = false
```

Then apply:
```bash
terraform apply
```

### Manual Backup Execution

```bash
# SSH into instance
ssh ubuntu@<instance-ip>

# Run backup manually
sudo /usr/local/bin/dokploy-backup.sh

# Check backup logs
sudo tail -f /var/log/dokploy-backup.log
```

## Important Notes

1. **Boot volume backups are automatic** once Terraform creates the policy - no manual action needed
2. **Object storage backups start on first boot** of the instance (after Terraform apply)
3. **Reserved IP prevents DNS issues** - your domain will keep working even if instance is recreated
4. **Backups run at different times** (2 AM for object storage, 3 AM for boot volumes) to reduce load
5. **Free tier limits:**
   - Boot volume backups: 5 backups total
   - Object storage: 20 GB total (10 GB Standard + 10 GB Archive)

## Testing Your Backups

**Test restore procedure in non-production:**

1. Create a test backup
2. Try restoring it to a new instance
3. Verify all services work
4. Document any issues

**Don't wait for a disaster to test your backups!**

## Quick Reference

| What You Need | Command |
|---------------|---------|
| List preserved boot volumes | `oci bv boot-volume list --compartment-id <id>` |
| List boot volume backups | `oci bv boot-volume-backup list --compartment-id <id>` |
| List object storage backups | `oci os object list --bucket-name <bucket> --namespace <ns>` |
| Quick recovery (terraform.tfvars) | `recovery_boot_volume_id = "ocid1.bootvolume..."` |
| Manual backup | `sudo /usr/local/bin/dokploy-backup.sh` |
| Backup logs | `journalctl -u dokploy-backup.service` |
| Timer status | `systemctl status dokploy-backup.timer` |
| Next scheduled backup | `systemctl list-timers dokploy-backup.timer` |

## Getting Help

If recovery fails:
1. Check `/var/log/dokploy-backup.log` for backup script errors
2. Check `journalctl -u dokploy-backup.service` for systemd errors
3. Verify OCI CLI is configured: `oci iam user get --user-id <your-user-id>`
4. Check object storage bucket access permissions
