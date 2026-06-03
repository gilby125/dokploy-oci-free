#!/bin/bash
set -euo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND"' ERR

# Komodo Periphery node bootstrap for OCI.
#
# This replaces the old Dokploy/Swarm bootstrap. Each OCI node runs a Komodo
# Periphery agent that the LOCAL Komodo Core (komodo.sdrcar.com / 192.168.1.200)
# manages over :8120. Auth is by the Core's PUBLIC key (passkey-less): the node
# trusts requests signed by PERIPHERY_CORE_PUBLIC_KEY, so no shared secret is
# distributed. Once the node shows up as a managed server in the Komodo UI, the
# Komodo Core stack and the agentplane stack are deployed onto it from there.

LOG_FILE="/var/log/komodo-periphery-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Starting Komodo Periphery configuration at $(date) ==="

# Idempotency guard
if [[ -f /var/lib/komodo/.configured ]]; then
    echo "System already configured, skipping..."
    exit 0
fi

# Constants
readonly DOCKER_INSTALL_URL="https://get.docker.com"
readonly DOCKER_INSTALL_SCRIPT="/tmp/docker-install-$$.sh"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly METADATA_BASE_URL="http://169.254.169.254/opc/v2/instance/metadata"
readonly METADATA_AUTH_HEADER="Authorization: Bearer Oracle"
readonly KOMODO_DIR="/opt/komodo"
readonly PERIPHERY_PORT=8120

readonly DOCKER_SCRIPT_SHA256="SKIP" # Set to a pinned hash or SKIP to bypass

verify_checksum() {
    local file="$1" expected_hash="$2" actual_hash
    if [[ "$expected_hash" == "SKIP" ]]; then
        echo "WARNING: Checksum verification skipped."
        return 0
    fi
    actual_hash=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: Checksum mismatch (expected $expected_hash, got $actual_hash)"
        return 1
    fi
    echo "Checksum verified"
}

download_with_retry() {
    local url="$1" dest="$2" retries=0
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

fetch_metadata() {
    local key="$1"
    curl -s -f -H "$METADATA_AUTH_HEADER" "${METADATA_BASE_URL}/${key}" || true
}

check_connectivity() {
    echo "Checking network connectivity..."
    for url in "https://get.docker.com" "https://ghcr.io"; do
        if ! curl -sf --head --connect-timeout 5 "$url" >/dev/null; then
            echo "ERROR: Cannot reach $url"
            return 1
        fi
    done
    echo "✓ Network connectivity verified"
}

# --- Load config from instance metadata ---------------------------------------
KOMODO_CORE_PUBLIC_KEY="$(fetch_metadata "komodo_core_public_key")"
KOMODO_IMAGE_TAG="$(fetch_metadata "komodo_image_tag")"
[[ -z "$KOMODO_IMAGE_TAG" ]] && KOMODO_IMAGE_TAG="2"

if [[ -z "$KOMODO_CORE_PUBLIC_KEY" ]]; then
    echo "ERROR: komodo_core_public_key metadata value is required"
    exit 1
fi

# --- Wait for cloud-init apt activity, then prep apt --------------------------
echo "Waiting for apt-daily services to complete..."
systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" --wait /bin/true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

for proc in apt apt-get; do
    if pgrep "$proc" >/dev/null; then
        pkill -TERM "$proc" || true
        sleep 3
        pgrep "$proc" >/dev/null && pkill -KILL "$proc" || true
    fi
done
sleep 5

echo "Waiting for apt locks to be released..."
LOCK_RELEASED=false
for i in {1..60}; do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo "Apt locks released after $i attempts"
        LOCK_RELEASED=true
        break
    fi
    sleep 2
done
[[ "$LOCK_RELEASED" == false ]] && { echo "ERROR: apt still locked after 60 attempts"; exit 1; }

apt update || { echo "ERROR: apt update failed"; exit 1; }

# --- ubuntu sudoers + SSH hardening -------------------------------------------
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-cloud-init-users
chmod 440 /etc/sudoers.d/90-cloud-init-users
visudo -c -f /etc/sudoers.d/90-cloud-init-users || { rm /etc/sudoers.d/90-cloud-init-users; exit 1; }

apt install -y openssh-server || { echo "ERROR: openssh-server install failed"; exit 1; }
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
ClientAliveInterval 120
ClientAliveCountMax 3
MaxAuthTries 3
EOF
sshd -t || { rm -f /etc/ssh/sshd_config.d/99-hardening.conf; exit 1; }
systemctl restart sshd || { echo "ERROR: sshd restart failed"; exit 1; }
systemctl is-active --quiet sshd || { echo "ERROR: sshd not running"; exit 1; }

# --- Docker -------------------------------------------------------------------
check_connectivity || { echo "ERROR: connectivity check failed"; exit 1; }
echo "Downloading Docker installation script..."
download_with_retry "$DOCKER_INSTALL_URL" "$DOCKER_INSTALL_SCRIPT" || { echo "ERROR: Docker script download failed"; exit 1; }
chmod 644 "$DOCKER_INSTALL_SCRIPT"
verify_checksum "$DOCKER_INSTALL_SCRIPT" "$DOCKER_SCRIPT_SHA256" || { rm -f "$DOCKER_INSTALL_SCRIPT"; exit 1; }
sh "$DOCKER_INSTALL_SCRIPT" || { echo "ERROR: Docker install failed"; rm -f "$DOCKER_INSTALL_SCRIPT"; exit 1; }
rm -f "$DOCKER_INSTALL_SCRIPT"
usermod -aG docker ubuntu || echo "WARNING: could not add ubuntu to docker group"
systemctl is-active --quiet docker || { echo "ERROR: docker not running"; exit 1; }
echo "Docker version: $(docker --version)"

# --- Firewall: allow the Komodo Core to reach Periphery on :8120 --------------
# OCI security-list scoping (to the Core's egress IP only) is handled in
# network.tf; this just makes the host accept the port.
iptables -I INPUT 1 -p tcp --dport "$PERIPHERY_PORT" -j ACCEPT
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || echo "WARNING: failed to persist iptables rules"
fi

# --- Komodo Periphery ---------------------------------------------------------
mkdir -p "$KOMODO_DIR/keys" /etc/komodo

cat >"$KOMODO_DIR/compose.env" <<EOF
COMPOSE_KOMODO_IMAGE_TAG=${KOMODO_IMAGE_TAG}
TZ=Etc/UTC
PERIPHERY_ROOT_DIRECTORY=/etc/komodo
PERIPHERY_SSL_ENABLED=true
# Trust the local Komodo Core by its public key (passkey-less auth).
PERIPHERY_CORE_PUBLIC_KEY=${KOMODO_CORE_PUBLIC_KEY}
PERIPHERY_DISABLE_TERMINALS=false
PERIPHERY_LOGGING_PRETTY=false
EOF
chmod 600 "$KOMODO_DIR/compose.env"

cat >"$KOMODO_DIR/docker-compose.yml" <<'EOF'
services:
  periphery:
    image: ghcr.io/moghtech/komodo-periphery:${COMPOSE_KOMODO_IMAGE_TAG:-2}
    init: true
    labels:
      komodo.skip: # never let Komodo stop its own agent
    restart: unless-stopped
    env_file: ./compose.env
    ports:
      - "8120:8120" # remote Core reaches this node here (scoped in network.tf)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      - ${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}:${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}
      - ./keys:/config/keys
EOF

echo "Starting Komodo Periphery..."
docker compose --project-directory "$KOMODO_DIR" --env-file "$KOMODO_DIR/compose.env" up -d || {
    echo "ERROR: failed to start Komodo Periphery"
    exit 1
}

# --- Done ---------------------------------------------------------------------
mkdir -p /var/lib/komodo
date >/var/lib/komodo/.configured
echo "=== Komodo Periphery configuration complete at $(date) ==="
echo "Add this node in Komodo as a server at https://<this-node-ip>:${PERIPHERY_PORT}"
