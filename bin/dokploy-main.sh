#!/bin/bash
set -euo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

# Setup logging
LOG_FILE="/var/log/dokploy-main-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Starting Dokploy main configuration at $(date) ==="

# Check if already configured
if [[ -f /var/lib/dokploy/.configured ]]; then
    echo "System already configured, skipping..."
    exit 0
fi

# Constants
readonly DOCKER_INSTALL_URL="https://get.docker.com"
readonly DOKPLOY_INSTALL_URL="https://dokploy.com/install.sh"
readonly DOCKER_INSTALL_SCRIPT="/tmp/docker-install-$$.sh"
readonly DOKPLOY_INSTALL_SCRIPT="/tmp/dokploy-install-$$.sh"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly METADATA_BASE_URL="http://169.254.169.254/opc/v2/instance/metadata"
readonly METADATA_AUTH_HEADER="Authorization: Bearer Oracle"
readonly TRAEFIK_DYNAMIC_DIR="/etc/dokploy/traefik/dynamic"

# Known good checksums (update these when upgrading)
# To get current checksums: curl -sSL https://get.docker.com | sha256sum
readonly DOCKER_SCRIPT_SHA256="SKIP"  # Set to specific hash or SKIP to bypass verification
readonly DOKPLOY_SCRIPT_SHA256="SKIP"  # Set to specific hash or SKIP to bypass verification

# Function to verify checksum
verify_checksum() {
    local file="$1"
    local expected_hash="$2"

    if [[ "$expected_hash" == "SKIP" ]]; then
        echo "WARNING: Checksum verification skipped. This is not recommended for production."
        return 0
    fi

    local actual_hash
    actual_hash=$(sha256sum "$file" | awk '{print $1}')

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: Checksum verification failed!"
        echo "Expected: $expected_hash"
        echo "Got:      $actual_hash"
        return 1
    fi

    echo "Checksum verified successfully"
    return 0
}

# Function to download with retry
download_with_retry() {
    local url="$1"
    local dest="$2"
    local retries=0

    while [[ $retries -lt $MAX_RETRIES ]]; do
        if curl -fsSL --connect-timeout 10 "$url" -o "$dest"; then
            return 0
        fi
        ((retries++))
        echo "Download attempt $retries failed, retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    done

    return 1
}

# Fetch instance metadata from OCI metadata service
fetch_metadata() {
    local key="$1"
    curl -s -f -H "$METADATA_AUTH_HEADER" "${METADATA_BASE_URL}/${key}" || true
}

# Function to check network connectivity
check_connectivity() {
    echo "Checking network connectivity..."
    local test_urls=("https://get.docker.com" "https://dokploy.com")

    for url in "${test_urls[@]}"; do
        if ! curl -sf --head --connect-timeout 5 "$url" > /dev/null; then
            echo "ERROR: Cannot reach $url"
            return 1
        fi
    done
    echo "✓ Network connectivity verified"
    return 0
}

# Load domain and access control list from instance metadata
DOKPLOY_DOMAINS_RAW="$(fetch_metadata "dokploy_domains")"
ADMIN_ACCESS_CIDRS="$(fetch_metadata "admin_access_cidrs")"

if [[ -z "${DOKPLOY_DOMAINS_RAW:-}" ]]; then
    echo "ERROR: dokploy_domains metadata value is required"
    exit 1
fi

IFS=',' read -r -a DOKPLOY_DOMAINS <<< "${DOKPLOY_DOMAINS_RAW}"

# Trim whitespace and discard empty entries
TEMP_DOMAINS=()
for domain in "${DOKPLOY_DOMAINS[@]}"; do
    trimmed="$(echo "$domain" | xargs)"
    if [[ -n "$trimmed" ]]; then
        TEMP_DOMAINS+=("$trimmed")
    fi
done
DOKPLOY_DOMAINS=("${TEMP_DOMAINS[@]}")

if [[ ${#DOKPLOY_DOMAINS[@]} -eq 0 ]]; then
    echo "ERROR: No valid domains provided in dokploy_domains metadata value"
    exit 1
fi

PRIMARY_DOKPLOY_DOMAIN="${DOKPLOY_DOMAINS[0]}"
DOKPLOY_DOMAIN="$PRIMARY_DOKPLOY_DOMAIN"

IFS=',' read -r -a ACCESS_CIDRS_ARRAY <<< "${ADMIN_ACCESS_CIDRS:-}"
ACCESS_CIDRS=()
for cidr in "${ACCESS_CIDRS_ARRAY[@]}"; do
    cidr_trimmed="$(echo "$cidr" | xargs)"
    if [[ -n "$cidr_trimmed" ]]; then
        ACCESS_CIDRS+=("$cidr_trimmed")
    fi
done

if [[ ${#ACCESS_CIDRS[@]} -eq 0 ]]; then
    echo "WARNING: No admin access CIDRs provided; Traefik whitelist will be empty"
fi

# Wait for cloud-init's apt-daily services to complete using systemd
echo "Waiting for apt-daily services to complete..."
systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" --wait /bin/true

# Disable apt-daily services permanently to prevent race conditions
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# Gracefully terminate apt processes
for proc in apt apt-get; do
    if pgrep "$proc" > /dev/null; then
        echo "Terminating $proc processes gracefully..."
        pkill -TERM "$proc" || true
        sleep 3
        # Force kill only if still running
        if pgrep "$proc" > /dev/null; then
            echo "Force killing $proc processes..."
            pkill -KILL "$proc" || true
        fi
    fi
done
sleep 5

# Wait for all apt locks to be released
echo "Waiting for apt locks to be fully released..."
LOCK_RELEASED=false
for i in {1..60}; do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo "Apt locks released after $i attempts"
        LOCK_RELEASED=true
        break
    fi
    echo "Attempt $i: Apt still locked, waiting..."
    sleep 2
done

if [ "$LOCK_RELEASED" = false ]; then
    echo "ERROR: Failed to acquire apt locks after 60 attempts"
    exit 1
fi

echo "System ready. Starting configuration..."

# Update package lists
apt update || {
    echo "ERROR: Failed to update package lists"
    exit 1
}

# NOTE: Root SSH access is disabled via SSH hardening configuration
# Ubuntu user has sudo access for administrative tasks

# Add ubuntu user to sudoers using sudoers.d
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-cloud-init-users
chmod 440 /etc/sudoers.d/90-cloud-init-users
visudo -c -f /etc/sudoers.d/90-cloud-init-users || {
    echo "ERROR: Invalid sudoers configuration"
    rm /etc/sudoers.d/90-cloud-init-users
    exit 1
}

# Install OpenSSH
apt install -y openssh-server || {
    echo "ERROR: Failed to install openssh-server"
    exit 1
}

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Configure SSH - only allow key-based authentication, disable password auth
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
ClientAliveInterval 120
ClientAliveCountMax 3
MaxAuthTries 3
EOF

# Test configuration before restarting
sshd -t || {
    echo "ERROR: SSH configuration test failed"
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
}

systemctl restart sshd || {
    echo "ERROR: Failed to restart sshd"
    exit 1
}

# Verify SSH is running
if ! systemctl is-active --quiet sshd; then
    echo "ERROR: SSH service is not running"
    exit 1
fi

# Check network connectivity
if ! check_connectivity; then
    echo "ERROR: Network connectivity check failed"
    exit 1
fi

# Download Docker installation script
echo "Downloading Docker installation script..."
if ! download_with_retry "$DOCKER_INSTALL_URL" "$DOCKER_INSTALL_SCRIPT"; then
    echo "ERROR: Failed to download Docker installation script after $MAX_RETRIES attempts"
    exit 1
fi

# Make script readable for inspection
chmod 644 "$DOCKER_INSTALL_SCRIPT"

# Verify checksum
if ! verify_checksum "$DOCKER_INSTALL_SCRIPT" "$DOCKER_SCRIPT_SHA256"; then
    echo "ERROR: Docker script checksum verification failed"
    rm -f "$DOCKER_INSTALL_SCRIPT"
    exit 1
fi

# Log script header for audit
echo "Docker script header (first 10 lines):"
head -10 "$DOCKER_INSTALL_SCRIPT"

# Execute installation
if ! sh "$DOCKER_INSTALL_SCRIPT"; then
    echo "ERROR: Docker installation failed"
    rm -f "$DOCKER_INSTALL_SCRIPT"
    exit 1
fi

# Clean up
rm -f "$DOCKER_INSTALL_SCRIPT"

# Add ubuntu user to docker group
usermod -aG docker ubuntu || echo "WARNING: Failed to add ubuntu to docker group"

# Verify Docker is running
if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker service is not running"
    exit 1
fi

echo "Docker version: $(docker --version)"

# Configure firewall rules so Swarm workers can join this manager
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || echo "WARNING: Failed to persist iptables rules"
fi

# Download Dokploy installation script
echo "Downloading Dokploy installation script..."
if ! download_with_retry "$DOKPLOY_INSTALL_URL" "$DOKPLOY_INSTALL_SCRIPT"; then
    echo "ERROR: Failed to download Dokploy installation script after $MAX_RETRIES attempts"
    exit 1
fi

# Make script readable for inspection
chmod 644 "$DOKPLOY_INSTALL_SCRIPT"

# Verify checksum
if ! verify_checksum "$DOKPLOY_INSTALL_SCRIPT" "$DOKPLOY_SCRIPT_SHA256"; then
    echo "ERROR: Dokploy script checksum verification failed"
    rm -f "$DOKPLOY_INSTALL_SCRIPT"
    exit 1
fi

# Log script header for audit
echo "Dokploy script header (first 10 lines):"
head -10 "$DOKPLOY_INSTALL_SCRIPT"

# Execute installation
if ! sh "$DOKPLOY_INSTALL_SCRIPT"; then
    echo "ERROR: Dokploy installation failed"
    rm -f "$DOKPLOY_INSTALL_SCRIPT"
    exit 1
fi

# Clean up
rm -f "$DOKPLOY_INSTALL_SCRIPT"

# Final validation
echo "=== Configuration Validation ==="

if systemctl is-active --quiet docker; then
    echo "✓ Docker is running"
else
    echo "✗ Docker is not running"
    exit 1
fi

if systemctl is-active --quiet sshd; then
    echo "✓ SSH service is running"
else
    echo "✗ SSH service is not running"
    exit 1
fi

# Wait for Dokploy to be ready
echo "Waiting for Dokploy to start..."
for i in {1..60}; do
    if docker ps | grep -q dokploy; then
        echo "✓ Dokploy container is running"
        break
    fi
    echo "Attempt $i: Waiting for Dokploy..."
    sleep 5
done

# Ensure a stable overlay network exists for app-to-app DNS
echo "Ensuring overlay network 'dokploy-network' exists..."
if ! docker network ls --format '{{.Name}}' | grep -qx 'dokploy-network'; then
    if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qi 'active'; then
        docker network create --driver overlay --attachable dokploy-network || echo "WARNING: Failed to create overlay network 'dokploy-network'"
    else
        # Fallback for non-swarm (should not happen on manager, but safe-guard)
        docker network create --driver bridge dokploy-network || echo "WARNING: Failed to create bridge network 'dokploy-network'"
    fi
else
    echo "✓ Overlay network 'dokploy-network' already present"
fi

# Configure Traefik routing for HTTPS access to Dokploy
echo "Configuring Traefik for domains: ${DOKPLOY_DOMAINS[*]}..."
mkdir -p "$TRAEFIK_DYNAMIC_DIR"

tmp_middlewares="$(mktemp)"
if [[ ${#ACCESS_CIDRS[@]} -eq 0 ]]; then
    cat <<'EOF' > "$tmp_middlewares"
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
    admin-ip-whitelist:
      ipWhiteList:
        sourceRange: []
EOF
else
    cat <<'EOF' > "$tmp_middlewares"
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
    admin-ip-whitelist:
      ipWhiteList:
        sourceRange:
EOF
    for cidr in "${ACCESS_CIDRS[@]}"; do
        printf '          - %s\n' "$cidr" >> "$tmp_middlewares"
    done
fi
mv "$tmp_middlewares" "${TRAEFIK_DYNAMIC_DIR}/middlewares.yml"

HOST_RULE=""
for domain in "${DOKPLOY_DOMAINS[@]}"; do
    if [[ -n "$HOST_RULE" ]]; then
        HOST_RULE+=" || "
    fi
    HOST_RULE+="Host(\`${domain}\`)"
done

tmp_dokploy="$(mktemp)"
cat <<EOF > "$tmp_dokploy"
http:
  routers:
    dokploy-http:
      rule: ${HOST_RULE}
      entryPoints:
        - web
      middlewares:
        - redirect-to-https
      service: dokploy-service-app
    dokploy-https:
      rule: ${HOST_RULE}
      entryPoints:
        - websecure
      middlewares:
        - admin-ip-whitelist
      tls:
        certResolver: letsencrypt
      service: dokploy-service-app
  services:
    dokploy-service-app:
      loadBalancer:
        servers:
          - url: http://dokploy:3000
        passHostHeader: true
EOF

mv "$tmp_dokploy" "${TRAEFIK_DYNAMIC_DIR}/dokploy.yml"

chmod 640 "${TRAEFIK_DYNAMIC_DIR}/middlewares.yml" "${TRAEFIK_DYNAMIC_DIR}/dokploy.yml"

if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qi 'manager'; then
    if docker service ls --filter name=dokploy-traefik --format '{{.Name}}' | grep -q '^dokploy-traefik$'; then
        echo "Reloading Traefik service via docker swarm..."
        docker service update --force dokploy-traefik || echo "WARNING: Failed to force update Traefik service"
    fi
else
    traefik_container_id=$(docker ps --filter name=dokploy-traefik --format '{{.ID}}' | head -n1 || true)
    if [[ -n "${traefik_container_id:-}" ]]; then
        echo "Restarting Traefik container..."
        docker restart "$traefik_container_id" || echo "WARNING: Failed to restart Traefik container"
    fi
fi

# Configure automated backups to OCI Object Storage
ENABLE_BACKUP="$(fetch_metadata "enable_automated_backup")"
BACKUP_BUCKET="$(fetch_metadata "backup_bucket")"
BACKUP_NAMESPACE="$(fetch_metadata "backup_namespace")"
BACKUP_SCRIPT_B64="$(fetch_metadata "backup_script")"

if [[ "${ENABLE_BACKUP}" == "true" ]] && [[ -n "${BACKUP_BUCKET}" ]] && [[ -n "${BACKUP_NAMESPACE}" ]]; then
    echo "=== Configuring automated backups ==="

    # Install OCI CLI if not present
    if ! command -v oci &> /dev/null; then
        echo "Installing OCI CLI..."
        bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- \
            --accept-all-defaults \
            --install-dir /opt/oci-cli \
            --exec-dir /usr/local/bin
    fi

    # Create backup script from metadata
    if [[ -n "${BACKUP_SCRIPT_B64}" ]]; then
        echo "Installing backup script..."
        echo "${BACKUP_SCRIPT_B64}" | base64 -d > /usr/local/bin/dokploy-backup.sh
        chmod +x /usr/local/bin/dokploy-backup.sh

        # Substitute environment variables in script
        cat > /etc/environment.d/dokploy-backup.conf << EOF
BACKUP_BUCKET=${BACKUP_BUCKET}
OCI_NAMESPACE=${BACKUP_NAMESPACE}
EOF

        # Create systemd service
        cat > /etc/systemd/system/dokploy-backup.service << 'EOF'
[Unit]
Description=Dokploy Backup to OCI Object Storage
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/environment.d/dokploy-backup.conf
ExecStart=/usr/local/bin/dokploy-backup.sh
StandardOutput=journal
StandardError=journal
EOF

        # Create systemd timer (runs daily at 2 AM UTC)
        cat > /etc/systemd/system/dokploy-backup.timer << 'EOF'
[Unit]
Description=Daily Dokploy Backup Timer
Requires=dokploy-backup.service

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

        # Reload systemd and enable timer
        systemctl daemon-reload
        systemctl enable dokploy-backup.timer
        systemctl start dokploy-backup.timer

        echo "✓ Automated backup configured (runs daily at 2 AM UTC)"
        echo "  Bucket: ${BACKUP_BUCKET}"
        echo "  Namespace: ${BACKUP_NAMESPACE}"
        echo "  Manual backup: sudo /usr/local/bin/dokploy-backup.sh"
        echo "  View timer status: systemctl status dokploy-backup.timer"
        echo "  View backup logs: journalctl -u dokploy-backup.service"
    else
        echo "WARNING: Backup script metadata not available"
    fi
else
    echo "Automated backups disabled or not configured"
fi

echo "=== Dokploy main configuration completed successfully at $(date) ==="

# Mark as configured
mkdir -p /var/lib/dokploy
touch /var/lib/dokploy/.configured
