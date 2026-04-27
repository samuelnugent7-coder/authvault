#!/usr/bin/env bash
# AuthVault — Linux installer
# Usage:  curl -fsSL https://raw.githubusercontent.com/samuelnugent7-coder/authvault/main/install.sh | bash
# Or:     bash install.sh [--dir /opt/authvault] [--port 8443] [--no-service]

set -euo pipefail

REPO="samuelnugent7-coder/authvault"
INSTALL_DIR="/opt/authvault"
PORT="8443"
NO_SERVICE=false
BINARY_NAME="authvault-api-linux"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     INSTALL_DIR="$2"; shift 2 ;;
    --port)    PORT="$2";        shift 2 ;;
    --no-service) NO_SERVICE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[authvault]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[authvault]\033[0m $*"; }
err()   { echo -e "\033[1;31m[authvault]\033[0m $*" >&2; exit 1; }

need_cmd() { command -v "$1" &>/dev/null || err "Required command not found: $1"; }
need_cmd curl
need_cmd tar

# ── Fetch latest release URL ──────────────────────────────────────────────────
info "Fetching latest release from GitHub..."
API_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o "\"browser_download_url\": \"[^\"]*${BINARY_NAME}[^\"]*\"" \
  | head -1 | cut -d'"' -f4)

[[ -z "$API_URL" ]] && err "Could not find binary in latest release. Check https://github.com/${REPO}/releases"

# ── Install ───────────────────────────────────────────────────────────────────
info "Installing to ${INSTALL_DIR} ..."
sudo mkdir -p "$INSTALL_DIR"
curl -fsSL "$API_URL" -o /tmp/authvault-api
sudo mv /tmp/authvault-api "${INSTALL_DIR}/authvault-api"
sudo chmod +x "${INSTALL_DIR}/authvault-api"
ok "Binary installed at ${INSTALL_DIR}/authvault-api"

# ── systemd service ───────────────────────────────────────────────────────────
if [[ "$NO_SERVICE" == false ]] && command -v systemctl &>/dev/null; then
  info "Creating systemd service..."
  sudo tee /etc/systemd/system/authvault.service >/dev/null <<EOF
[Unit]
Description=AuthVault API Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/authvault-api
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable authvault
  ok "Systemd service created. Run: sudo systemctl start authvault"
else
  info "Skipping systemd setup (--no-service or systemctl not found)."
fi

# ── First-run hint ────────────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  AuthVault installed!                                       │"
echo "│                                                             │"
echo "│  First run:                                                 │"
echo "│    cd ${INSTALL_DIR}"
echo "│    sudo ./authvault-api                                     │"
echo "│                                                             │"
echo "│  It will print your CLIENT SECRET — save it.               │"
echo "│  Then start the service:                                    │"
echo "│    sudo systemctl start authvault                           │"
echo "└─────────────────────────────────────────────────────────────┘"
