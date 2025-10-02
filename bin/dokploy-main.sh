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

# Configure firewall rules for Docker Swarm
# Note: Using iptables directly since OCI instances use iptables by default
# ufw may not be installed or enabled

iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 3000 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 996 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT

# Reorder FORWARD chain rules:
# Remove the default REJECT rule (ignore error if not found)
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited || true
# Append the REJECT rule at the end so that Docker rules can be matched first
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited

netfilter-persistent save

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

if iptables -L INPUT -n | grep -q "2377"; then
    echo "✓ Docker Swarm firewall rules are configured"
else
    echo "✗ Docker Swarm firewall rules may be missing"
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

echo "=== Dokploy main configuration completed successfully at $(date) ==="

# Mark as configured
mkdir -p /var/lib/dokploy
touch /var/lib/dokploy/.configured