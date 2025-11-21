#!/bin/bash
# Backup Docker and Dokploy data to OCI Object Storage
# This script is run via systemd timer (daily at 2 AM UTC)

set -euo pipefail

# Configuration (populated by Terraform via instance metadata)
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
OCI_NAMESPACE="${OCI_NAMESPACE:-}"
BACKUP_DIR="/var/backups/dokploy"
MAX_LOCAL_BACKUPS=3
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PREFIX="dokploy-backup-${TIMESTAMP}"

# Logging
LOG_FILE="/var/log/dokploy-backup.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Starting backup at $(date) ==="

# Verify OCI CLI is available
if ! command -v oci &> /dev/null; then
    echo "ERROR: OCI CLI not installed. Installing..."
    # Install OCI CLI
    bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
    export PATH="$PATH:/root/bin"
fi

# Verify configuration
if [[ -z "$BACKUP_BUCKET" ]] || [[ -z "$OCI_NAMESPACE" ]]; then
    echo "ERROR: BACKUP_BUCKET or OCI_NAMESPACE not set"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Function to create compressed backup
create_backup() {
    local source_dir="$1"
    local backup_name="$2"
    local backup_file="${BACKUP_DIR}/${backup_name}.tar.gz"

    echo "Creating backup of ${source_dir}..."

    if [[ ! -d "$source_dir" ]]; then
        echo "WARNING: ${source_dir} does not exist, skipping"
        return 1
    fi

    # Create compressed archive with progress
    tar -czf "$backup_file" \
        --directory="$(dirname "$source_dir")" \
        "$(basename "$source_dir")" \
        2>&1 | grep -v "Removing leading"

    echo "✓ Created ${backup_file} ($(du -h "$backup_file" | cut -f1))"
    echo "$backup_file"
}

# Function to upload to object storage
upload_to_oci() {
    local file="$1"
    local object_name="$(basename "$file")"

    echo "Uploading ${object_name} to OCI Object Storage..."

    if oci os object put \
        --bucket-name "$BACKUP_BUCKET" \
        --namespace "$OCI_NAMESPACE" \
        --file "$file" \
        --name "$object_name" \
        --force; then
        echo "✓ Uploaded ${object_name} successfully"
        return 0
    else
        echo "✗ Failed to upload ${object_name}"
        return 1
    fi
}

# Function to clean up old local backups
cleanup_old_backups() {
    echo "Cleaning up old local backups (keeping last ${MAX_LOCAL_BACKUPS})..."

    # Remove old backup files, keeping only the most recent ones
    cd "$BACKUP_DIR" || return
    ls -t dokploy-backup-*.tar.gz 2>/dev/null | tail -n +$((MAX_LOCAL_BACKUPS + 1)) | xargs -r rm -f

    echo "✓ Cleanup complete"
}

# Stop Docker services temporarily for consistent backup
echo "Stopping Dokploy services for consistent backup..."
if docker ps --format '{{.Names}}' | grep -q dokploy; then
    docker stop $(docker ps -q --filter name=dokploy) || true
    STOPPED_DOKPLOY=true
else
    STOPPED_DOKPLOY=false
fi

# Wait for services to stop
sleep 5

# Backup Docker volumes (contains all application data)
DOCKER_VOLUMES_BACKUP=$(create_backup "/var/lib/docker/volumes" "${BACKUP_PREFIX}-docker-volumes")

# Backup Dokploy configuration and database
DOKPLOY_DATA_BACKUP=$(create_backup "/var/lib/dokploy" "${BACKUP_PREFIX}-dokploy-data")

# Restart services
if [[ "$STOPPED_DOKPLOY" == "true" ]]; then
    echo "Restarting Dokploy services..."
    docker start $(docker ps -aq --filter name=dokploy) || true
fi

# Upload backups to OCI Object Storage
UPLOAD_SUCCESS=true

if [[ -f "$DOCKER_VOLUMES_BACKUP" ]]; then
    upload_to_oci "$DOCKER_VOLUMES_BACKUP" || UPLOAD_SUCCESS=false
fi

if [[ -f "$DOKPLOY_DATA_BACKUP" ]]; then
    upload_to_oci "$DOKPLOY_DATA_BACKUP" || UPLOAD_SUCCESS=false
fi

# Clean up old local backups
cleanup_old_backups

# Summary
echo "=== Backup completed at $(date) ==="
if [[ "$UPLOAD_SUCCESS" == "true" ]]; then
    echo "✓ All backups uploaded successfully"
    exit 0
else
    echo "✗ Some backups failed to upload"
    exit 1
fi
