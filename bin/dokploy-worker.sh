#!/bin/bash
set -euo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

# Setup logging
LOG_FILE="/var/log/dokploy-worker-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Starting Dokploy worker configuration at $(date) ==="

# Check if already configured
if [[ -f /var/lib/dokploy-worker/.configured ]]; then
    echo "System already configured, skipping..."
    exit 0
fi

# Constants
readonly DOCKER_INSTALL_URL="https://get.docker.com"
readonly DOCKER_INSTALL_SCRIPT="/tmp/docker-install-$$.sh"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

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
    local test_urls=("https://get.docker.com")

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

# Add ubuntu SSH authorized keys to the root user
if [ ! -f /home/ubuntu/.ssh/authorized_keys ]; then
    echo "ERROR: /home/ubuntu/.ssh/authorized_keys not found"
    exit 1
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh
chown root:root /root/.ssh

cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/ || {
    echo "ERROR: Failed to copy authorized_keys"
    exit 1
}
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Verify permissions
if [[ $(stat -c %a /root/.ssh) != "700" ]]; then
    echo "ERROR: Failed to set correct permissions on /root/.ssh"
    exit 1
fi

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
PermitRootLogin prohibit-password
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

# Configure firewall rules for Docker Swarm
# Note: Using iptables directly since OCI instances use iptables by default
# ufw may not be installed or enabled

iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
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

echo "=== Dokploy worker configuration completed successfully at $(date) ==="

# Mark as configured
mkdir -p /var/lib/dokploy-worker
touch /var/lib/dokploy-worker/.configured