#!/bin/bash
set -euo pipefail
trap 'echo "Error on line $LINENO"' ERR

# Setup logging
LOG_FILE="/var/log/dokploy-worker-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Starting Dokploy worker configuration at $(date) ==="

# Wait for cloud-init's apt-daily services to complete using systemd
echo "Waiting for apt-daily services to complete..."
systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" --wait /bin/true

# Disable apt-daily services permanently to prevent race conditions
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# Kill any remaining apt processes and wait for locks
killall -9 apt apt-get 2>/dev/null || true
sleep 10

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
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/ || {
    echo "ERROR: Failed to copy authorized_keys"
    exit 1
}
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

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

# Configure SSH - only allow key-based authentication, disable password auth
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

systemctl restart sshd || {
    echo "ERROR: Failed to restart sshd"
    exit 1
}

# Verify SSH is running
if ! systemctl is-active --quiet sshd; then
    echo "ERROR: SSH service is not running"
    exit 1
fi

# Install Docker
if ! curl -sSL https://get.docker.com | sh; then
    echo "ERROR: Docker installation failed"
    exit 1
fi

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