#!/usr/bin/env bash
# =============================================================================
#  Affix/CA  ·  Linux Installer
#  Installs Docker, creates a Docker Compose service, and starts Affix/CA
#  on port 443 (HTTPS).
#
#  Supports: Ubuntu/Debian, RHEL/CentOS/Fedora/Rocky/AlmaLinux
#
#  Usage:
#    sudo bash install.sh [--port 443] [--dir /opt/affix-ca] [--pass <secret>]
#
#  If run on an already-configured node, the script will pull the latest
#  container image from GHCR, recreate the container, and exit — preserving
#  all CA data, certificates, and keys.
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/affix-ca"
CA_PORT="443"
CA_HTTP_PORT="80"
CA_PASS=""
IMAGE="ghcr.io/jayarep/affix-ca:latest"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  CA_PORT="$2";     shift 2 ;;
        --dir)   INSTALL_DIR="$2"; shift 2 ;;
        --pass)  CA_PASS="$2";     shift 2 ;;
        --help)
            echo "Usage: sudo bash install.sh [--port 443] [--dir /opt/affix-ca] [--pass <secret>]"
            exit 0 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Try: sudo bash $0"
fi

# =============================================================================
#  Upgrade path — if already installed, pull latest image and recreate
# =============================================================================
if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    info "Existing installation detected at ${INSTALL_DIR}."

    # Capture the currently running image digest (before pull)
    OLD_DIGEST="$(docker inspect --format='{{.Image}}' affix-ca 2>/dev/null || echo "none")"

    info "Pulling latest image from GHCR..."
    cd "${INSTALL_DIR}"
    docker compose pull

    NEW_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null || echo "unknown")"

    if [[ "$OLD_DIGEST" == "none" ]]; then
        info "Container was not running. Starting with latest image..."
    else
        info "Recreating container with updated image..."
    fi

    docker compose up -d --force-recreate

    # ── Verify container came up ────────────────────────────────────────
    RETRIES=12
    until docker inspect -f '{{.State.Running}}' affix-ca 2>/dev/null | grep -q true; do
        RETRIES=$((RETRIES - 1))
        if [[ $RETRIES -le 0 ]]; then
            error "Container did not start within 60 s. Check logs: docker logs affix-ca"
        fi
        sleep 5
    done

    RUNNING_IMAGE="$(docker inspect --format='{{.Config.Image}}' affix-ca 2>/dev/null || echo "unknown")"

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  Affix/CA upgraded successfully!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  Image:        ${CYAN}${RUNNING_IMAGE}${NC}"
    echo -e "  Install dir:  ${INSTALL_DIR}"
    echo -e "  CA data:      Preserved (Docker volume 'ca-data')"
    echo ""
    echo -e "  Your CA configuration, certificates, and keys are untouched."
    echo -e "  Check logs:   ${CYAN}docker logs -f affix-ca${NC}"
    echo ""
    exit 0
fi

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
else
    error "Cannot detect OS. /etc/os-release not found."
fi

is_debian_like() { [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; }
is_rhel_like()   { [[ "$OS_ID" =~ ^(rhel|centos|fedora|rocky|almalinux|ol)$ || "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* ]]; }

# ── Generate a random password if not supplied ────────────────────────────────
generate_pass() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 48
    else
        tr -dc 'A-Za-z0-9+/' </dev/urandom | head -c 64
    fi
}

if [[ -z "$CA_PASS" ]]; then
    CA_PASS="$(generate_pass)"
fi

# =============================================================================
#  Step 1 – Install Docker Engine
# =============================================================================
install_docker_debian() {
    info "Installing Docker on Debian/Ubuntu..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${OS_ID} \
$(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
    info "Installing Docker on RHEL/CentOS/Fedora..."
    if command -v dnf &>/dev/null; then
        PKG="dnf"
    else
        PKG="yum"
    fi

    $PKG install -y -q yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    $PKG install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

if command -v docker &>/dev/null; then
    DOCKER_VER="$(docker --version)"
    warn "Docker is already installed: $DOCKER_VER — skipping Docker installation."
else
    if is_debian_like; then
        install_docker_debian
    elif is_rhel_like; then
        install_docker_rhel
    else
        error "Unsupported OS: ${OS_ID}. Install Docker manually then re-run this script."
    fi
    success "Docker installed."
fi

# ── Ensure Docker Compose v2 plugin is present ───────────────────────────────
if ! docker compose version &>/dev/null; then
    error "Docker Compose plugin not found. Please install 'docker-compose-plugin' and retry."
fi
success "Docker Compose v2 available: $(docker compose version --short)"

# ── Enable + start Docker daemon ──────────────────────────────────────────────
systemctl enable --now docker
success "Docker daemon is running."

# =============================================================================
#  Step 2 – Create install directory and secrets
# =============================================================================
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/secrets"

# Write the CA passphrase (readable only by root / docker daemon)
printf '%s' "${CA_PASS}" > "${INSTALL_DIR}/secrets/ca-pass.txt"
chmod 600 "${INSTALL_DIR}/secrets/ca-pass.txt"
success "CA passphrase written to ${INSTALL_DIR}/secrets/ca-pass.txt"

# =============================================================================
#  Step 3 – Write docker-compose.yml
# =============================================================================
info "Writing docker-compose.yml to ${INSTALL_DIR}..."

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
# =============================================================================
#  Affix/CA  ·  Standalone deployment (single container, full PKI)
#  Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

name: affix-ca

secrets:
  ca_pass:
    file: ./secrets/ca-pass.txt

volumes:
  ca-data:

services:
  affix-ca:
    image: ${IMAGE}
    container_name: affix-ca
    hostname: affix-ca
    ports:
      - "${CA_PORT}:8443"
      - "${CA_HTTP_PORT}:8080"
    volumes:
      - ca-data:/ca
    secrets:
      - ca_pass
    environment:
      CA_SECRET_FILE: /run/secrets/ca_pass
    restart: unless-stopped
EOF

success "docker-compose.yml written."

# =============================================================================
#  Step 4 – Create a systemd service unit
# =============================================================================
info "Installing systemd service: affix-ca.service"

cat > /etc/systemd/system/affix-ca.service <<'UNIT'
[Unit]
Description=Affix/CA PKI Service
Documentation=https://github.com/jayarep/affix-ca
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=INSTALL_DIR_PLACEHOLDER
ExecStart=/usr/bin/docker compose up -d --pull always
ExecStop=/usr/bin/docker compose down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# Patch in the actual install directory (heredoc was quoted to protect systemd syntax)
sed -i "s|INSTALL_DIR_PLACEHOLDER|${INSTALL_DIR}|g" /etc/systemd/system/affix-ca.service

systemctl daemon-reload
systemctl enable affix-ca.service
success "systemd service registered and enabled."

# =============================================================================
#  Step 5 – Pull image and start the service
# =============================================================================
info "Pulling image ${IMAGE} (this may take a moment)..."
cd "${INSTALL_DIR}"
docker compose pull

info "Starting Affix/CA..."
systemctl start affix-ca.service

# ── Verify container came up ──────────────────────────────────────────────────
RETRIES=12
until docker inspect -f '{{.State.Running}}' affix-ca 2>/dev/null | grep -q true; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -le 0 ]]; then
        error "Container did not start within 60 s. Check logs: docker logs affix-ca"
    fi
    sleep 5
done

success "Affix/CA container is running."

# =============================================================================
#  Done
# =============================================================================
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Affix/CA installed successfully!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  Web UI:       ${CYAN}https://${HOST_IP}:${CA_PORT}${NC}"
echo -e "  Install dir:  ${INSTALL_DIR}"
echo -e "  Secrets:      ${INSTALL_DIR}/secrets/ca-pass.txt"
echo ""
echo -e "  Manage the service:"
echo -e "    systemctl start   affix-ca"
echo -e "    systemctl stop    affix-ca"
echo -e "    systemctl restart affix-ca"
echo -e "    docker logs -f affix-ca"
echo ""
echo -e "${YELLOW}  Keep ${INSTALL_DIR}/secrets/ca-pass.txt safe — losing it means${NC}"
echo -e "${YELLOW}  losing access to your CA private keys.${NC}"
echo ""
