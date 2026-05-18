#!/usr/bin/env bash

# V2bX private lite installer: Xboard/V2board UniProxy + VLESS + Xray.
#
# Usage:
#   API_HOST=https://panel.example.com API_KEY=xxx DOWNLOAD_BASE=https://cdn.example.com bash install.sh <node_id>
#
# Optional:
#   INSTALL_DIR=/etc/V2bX SERVICE_NAME=v2bx bash install.sh <node_id>

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

API_HOST="${API_HOST:-}"
API_KEY="${API_KEY:-}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-}"
INSTALL_DIR="${INSTALL_DIR:-/etc/V2bX}"
SERVICE_NAME="${SERVICE_NAME:-v2bx}"
NODE_TYPE="${NODE_TYPE:-vless}"

usage() {
    echo -e "${RED}Usage:${NC}"
    echo "  API_HOST=https://panel.example.com API_KEY=xxx DOWNLOAD_BASE=https://cdn.example.com bash install.sh <node_id>"
    echo ""
    echo -e "${YELLOW}Required environment:${NC}"
    echo "  API_HOST       Xboard/V2board panel host, for example https://panel.example.com"
    echo "  API_KEY        UniProxy node API key"
    echo "  DOWNLOAD_BASE  Base URL containing v2bx-linux-amd64 and v2bx-linux-arm64"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ -z "${1:-}" ]; then
    echo -e "${RED}Error: missing node id.${NC}"
    usage
    exit 1
fi

if [ -z "$API_HOST" ] || [ -z "$API_KEY" ] || [ -z "$DOWNLOAD_BASE" ]; then
    echo -e "${RED}Error: API_HOST, API_KEY and DOWNLOAD_BASE are required.${NC}"
    usage
    exit 1
fi

NODE_ID="$1"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}      V2bX Private Lite Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}Node ID: $NODE_ID${NC}"
echo -e "${YELLOW}Panel:   $API_HOST${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
fi

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            echo -e "${YELLOW}Supported: amd64, arm64${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}Detected architecture: $ARCH${NC}"
}

enable_bbr() {
    echo -e "${GREEN}[1/4] Enabling BBR if available...${NC}"

    if lsmod | grep -q bbr; then
        echo -e "${YELLOW}BBR is already enabled.${NC}"
        return
    fi

    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    if [ "$KERNEL_MAJOR" -lt 4 ]; then
        echo -e "${YELLOW}Kernel is too old for BBR auto setup, skipping.${NC}"
        return
    fi

    if grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        sysctl -p >/dev/null 2>&1 || true
        echo -e "${GREEN}BBR sysctl already configured.${NC}"
        return
    fi

    cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p >/dev/null 2>&1 || true

    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR enabled.${NC}"
    else
        echo -e "${YELLOW}BBR was not enabled, continuing install.${NC}"
    fi
}

download_binary() {
    echo -e "${GREEN}[2/4] Downloading V2bX binary...${NC}"

    mkdir -p "$INSTALL_DIR"
    BINARY_URL="${DOWNLOAD_BASE%/}/v2bx-linux-${ARCH}"

    echo -e "${YELLOW}Download URL: $BINARY_URL${NC}"

    if ! wget -q --show-progress -O "$INSTALL_DIR/V2bX" "$BINARY_URL"; then
        echo -e "${RED}Download failed. Check network or DOWNLOAD_BASE.${NC}"
        exit 1
    fi

    chmod +x "$INSTALL_DIR/V2bX"
    ln -sf "$INSTALL_DIR/V2bX" /usr/local/bin/V2bX

    echo -e "${GREEN}Binary installed.${NC}"
}

configure() {
    echo -e "${GREEN}[3/4] Writing config...${NC}"

    cat > "$INSTALL_DIR/config.json" << EOF
{
  "Log": {
    "Level": "info"
  },
  "Cores": [
    {
      "Type": "xray",
      "Log": {
        "Level": "warning"
      }
    }
  ],
  "Nodes": [
    {
      "ApiHost": "$API_HOST",
      "ApiKey": "$API_KEY",
      "NodeID": $NODE_ID,
      "NodeType": "$NODE_TYPE",
      "Options": {
        "Core": "xray",
        "ListenIP": "0.0.0.0",
        "SendIP": "0.0.0.0"
      }
    }
  ]
}
EOF

    chmod 600 "$INSTALL_DIR/config.json"
    echo -e "${GREEN}Config written to $INSTALL_DIR/config.json.${NC}"
}

create_service() {
    echo -e "${GREEN}[4/4] Creating systemd service...${NC}"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=V2bX Private Lite Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/V2bX server -c $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Service started successfully.${NC}"
    else
        echo -e "${RED}Service failed to start. Run: journalctl -u $SERVICE_NAME -f${NC}"
        exit 1
    fi
}

show_info() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      V2bX Private Lite Installed${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Architecture: ${YELLOW}$ARCH${NC}"
    echo -e "Node ID:      ${YELLOW}$NODE_ID${NC}"
    echo -e "Panel:        ${YELLOW}$API_HOST${NC}"
    echo -e "Config:       ${YELLOW}$INSTALL_DIR/config.json${NC}"
    echo ""
    echo "Useful commands:"
    echo -e "  Status:  ${YELLOW}systemctl status $SERVICE_NAME${NC}"
    echo -e "  Logs:    ${YELLOW}journalctl -u $SERVICE_NAME -f${NC}"
    echo -e "  Restart: ${YELLOW}systemctl restart $SERVICE_NAME${NC}"
    echo ""
}

main() {
    detect_arch
    enable_bbr
    download_binary
    configure
    create_service
    show_info
}

main
