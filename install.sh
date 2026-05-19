#!/usr/bin/env bash

# V2bX private lite installer: Xboard/V2board UniProxy + VLESS + Xray.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/miliyao/phantom-node/main/install.sh) \
#     --node-id=1 \
#     --panel=https://panel.example.com \
#     --token=your_uniproxy_api_key
#
# Alternative:
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
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/miliyao/phantom-node/releases/latest/download}"
INSTALL_DIR="${INSTALL_DIR:-/etc/V2bX}"
SERVICE_NAME="${SERVICE_NAME:-v2bx}"
NODE_TYPE="${NODE_TYPE:-vless}"
NODE_ID="${NODE_ID:-}"
ENABLE_BBR="${ENABLE_BBR:-true}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"
GEO_ASSET_BASE="${GEO_ASSET_BASE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

usage() {
    echo -e "${RED}Usage:${NC}"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/miliyao/phantom-node/main/install.sh) \\"
    echo "    --node-id=1 \\"
    echo "    --panel=https://panel.example.com \\"
    echo "    --token=your_uniproxy_api_key"
    echo ""
    echo -e "${YELLOW}Alternative:${NC}"
    echo "  API_HOST=https://panel.example.com API_KEY=xxx DOWNLOAD_BASE=https://cdn.example.com bash install.sh <node_id>"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --node-id=ID       Xboard/V2board node id, comma-separated for multiple nodes"
    echo "  --panel=URL        Xboard/V2board panel host, for example https://panel.example.com"
    echo "  --token=TOKEN      UniProxy node API key"
    echo "  --download-base=URL  Base URL containing v2bx-linux-amd64 and v2bx-linux-arm64"
    echo "  --install-dir=PATH   Install directory, default /etc/V2bX"
    echo "  --service-name=NAME  systemd service name, default v2bx"
    echo "  --node-type=TYPE     Node type, default vless"
    echo "  --no-bbr             Skip BBR sysctl setup"
    echo "  --no-firewall        Skip iptables hardening rules"
    echo "  --geo-asset-base=URL      Base URL for geoip.dat and geosite.dat"
    echo "  --timezone=TZ       System timezone, default Asia/Shanghai"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --node-id=*)
                NODE_ID="${1#*=}"
                ;;
            --node-id)
                shift
                NODE_ID="${1:-}"
                ;;
            --panel=*)
                API_HOST="${1#*=}"
                ;;
            --panel)
                shift
                API_HOST="${1:-}"
                ;;
            --token=*)
                API_KEY="${1#*=}"
                ;;
            --token)
                shift
                API_KEY="${1:-}"
                ;;
            --download-base=*)
                DOWNLOAD_BASE="${1#*=}"
                ;;
            --download-base)
                shift
                DOWNLOAD_BASE="${1:-}"
                ;;
            --install-dir=*)
                INSTALL_DIR="${1#*=}"
                ;;
            --install-dir)
                shift
                INSTALL_DIR="${1:-}"
                ;;
            --service-name=*)
                SERVICE_NAME="${1#*=}"
                ;;
            --service-name)
                shift
                SERVICE_NAME="${1:-}"
                ;;
            --node-type=*)
                NODE_TYPE="${1#*=}"
                ;;
            --node-type)
                shift
                NODE_TYPE="${1:-}"
                ;;
            --no-bbr)
                ENABLE_BBR="false"
                ;;
            --no-firewall)
                ENABLE_FIREWALL="false"
                ;;
            --geo-asset-base=*)
                GEO_ASSET_BASE="${1#*=}"
                ;;
            --geo-asset-base)
                shift
                GEO_ASSET_BASE="${1:-}"
                ;;
            --timezone=*)
                TIMEZONE="${1#*=}"
                ;;
            --timezone)
                shift
                TIMEZONE="${1:-}"
                ;;
            --*)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
            *)
                if [ -z "$NODE_ID" ]; then
                    NODE_ID="$1"
                else
                    echo -e "${RED}Unexpected argument: $1${NC}"
                    usage
                    exit 1
                fi
                ;;
        esac
        shift
    done
}

parse_args "$@"

if [ -z "$NODE_ID" ]; then
    echo -e "${RED}Error: missing node id.${NC}"
    usage
    exit 1
fi

if [ -z "$API_HOST" ] || [ -z "$API_KEY" ]; then
    echo -e "${RED}Error: --panel and --token are required.${NC}"
    usage
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}      V2bX Private Lite Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}Node ID: $NODE_ID${NC}"
echo -e "${YELLOW}Panel:   $API_HOST${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
fi

configure_timezone() {
    echo -e "${GREEN}[1/8] Setting timezone to $TIMEZONE...${NC}"

    if [ -z "$TIMEZONE" ]; then
        echo -e "${YELLOW}Timezone is empty, skipping.${NC}"
        return
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "$TIMEZONE"
    elif [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" > /etc/timezone
    else
        echo -e "${YELLOW}Timezone data for $TIMEZONE not found, skipping.${NC}"
    fi
}

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

ensure_service_user() {
    if ! id -u v2bx >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin v2bx
    fi
}

configure() {
    echo -e "${GREEN}[3/7] Writing config...${NC}"

    nodes_json=""
    IFS=',' read -r -a node_id_list <<< "$NODE_ID"
    for raw_node_id in "${node_id_list[@]}"; do
        node_id="$(echo "$raw_node_id" | tr -d '[:space:]')"
        if [ -z "$node_id" ]; then
            continue
        fi
        if ! [[ "$node_id" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid node id: $node_id${NC}"
            exit 1
        fi

        if [ -n "$nodes_json" ]; then
            nodes_json="$nodes_json,"
        fi

        nodes_json="$nodes_json
    {
      \"ApiHost\": \"$API_HOST\",
      \"ApiKey\": \"$API_KEY\",
      \"NodeID\": $node_id,
      \"NodeType\": \"$NODE_TYPE\",
      \"Options\": {
        \"Core\": \"xray\",
        \"ListenIP\": \"0.0.0.0\",
        \"SendIP\": \"0.0.0.0\"
      }
    }"
    done

    if [ -z "$nodes_json" ]; then
        echo -e "${RED}No valid node ids provided.${NC}"
        exit 1
    fi

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
      },
      "RouteConfigPath": "$INSTALL_DIR/route.json",
      "OutboundConfigPath": "$INSTALL_DIR/outbounds.json",
      "DnsConfigPath": "$INSTALL_DIR/dns.json"
    }
  ],
  "Nodes": [
$nodes_json
  ]
}
EOF

    chown root:v2bx "$INSTALL_DIR/config.json"
    chmod 640 "$INSTALL_DIR/config.json"
    echo -e "${GREEN}Config written to $INSTALL_DIR/config.json.${NC}"
}

configure_route_rules() {
    echo -e "${GREEN}[4/5] Writing default route rules...${NC}"

    if [ ! -f "$INSTALL_DIR/outbounds.json" ]; then
        cat > "$INSTALL_DIR/outbounds.json" << 'EOF'
[
  {
    "tag": "direct",
    "protocol": "freedom"
  },
  {
    "tag": "block",
    "protocol": "blackhole"
  }
]
EOF
        chown root:v2bx "$INSTALL_DIR/outbounds.json"
        chmod 640 "$INSTALL_DIR/outbounds.json"
        echo -e "${GREEN}Created $INSTALL_DIR/outbounds.json.${NC}"
    else
        echo -e "${YELLOW}$INSTALL_DIR/outbounds.json exists, keeping current file.${NC}"
        chown root:v2bx "$INSTALL_DIR/outbounds.json"
        chmod 640 "$INSTALL_DIR/outbounds.json"
    fi

    if [ ! -f "$INSTALL_DIR/route.json" ]; then
        cat > "$INSTALL_DIR/route.json" << 'EOF'
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    {
      "type": "field",
      "protocol": ["bittorrent"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "ip": ["geoip:private"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "ip": ["geoip:cn"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "domain": ["geosite:cn"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "domain": ["geosite:category-ads-all"],
      "outboundTag": "block"
    }
  ]
}
EOF
        chown root:v2bx "$INSTALL_DIR/route.json"
        chmod 640 "$INSTALL_DIR/route.json"
        echo -e "${GREEN}Created $INSTALL_DIR/route.json.${NC}"
    else
        echo -e "${YELLOW}$INSTALL_DIR/route.json exists, keeping current file.${NC}"
        chown root:v2bx "$INSTALL_DIR/route.json"
        chmod 640 "$INSTALL_DIR/route.json"
    fi

    if [ ! -f "$INSTALL_DIR/dns.json" ]; then
        cat > "$INSTALL_DIR/dns.json" << 'EOF'
{
  "servers": [
    "8.8.8.8",
    "1.1.1.1"
  ]
}
EOF
        chown root:v2bx "$INSTALL_DIR/dns.json"
        chmod 640 "$INSTALL_DIR/dns.json"
        echo -e "${GREEN}Created $INSTALL_DIR/dns.json.${NC}"
    else
        echo -e "${YELLOW}$INSTALL_DIR/dns.json exists, keeping current file.${NC}"
        chown root:v2bx "$INSTALL_DIR/dns.json"
        chmod 640 "$INSTALL_DIR/dns.json"
    fi
}

download_geo_assets() {
    echo -e "${GREEN}[5/7] Ensuring geo assets...${NC}"

    for asset in geoip.dat geosite.dat; do
        path="$INSTALL_DIR/$asset"
        if [ -f "$path" ]; then
            echo -e "${YELLOW}$path exists, keeping current file.${NC}"
            chown root:v2bx "$path"
            chmod 640 "$path"
            continue
        fi

        url="${GEO_ASSET_BASE%/}/$asset"
        echo -e "${YELLOW}Downloading $asset from $url${NC}"
        if ! wget -q --show-progress -O "$path" "$url"; then
            echo -e "${RED}Failed to download $asset. geoip/geosite route rules require this file.${NC}"
            exit 1
        fi
        chown root:v2bx "$path"
        chmod 640 "$path"
    done
}

configure_firewall() {
    if [ "$ENABLE_FIREWALL" != "true" ]; then
        echo -e "${YELLOW}[6/7] Skipping firewall hardening.${NC}"
        return
    fi

    echo -e "${GREEN}[6/7] Applying firewall hardening...${NC}"

    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${YELLOW}iptables not found, skipping firewall hardening.${NC}"
        return
    fi

    if ! iptables -C OUTPUT -m owner --uid-owner v2bx -p icmp -j REJECT 2>/dev/null; then
        iptables -A OUTPUT -m owner --uid-owner v2bx -p icmp -j REJECT
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
}

create_service() {
    echo -e "${GREEN}[7/7] Creating systemd service...${NC}"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=V2bX Private Lite Service
After=network.target

[Service]
Type=simple
User=v2bx
Group=v2bx
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
    configure_timezone
    detect_arch
    if [ "$ENABLE_BBR" = "true" ]; then
        enable_bbr
    else
        echo -e "${YELLOW}[1/4] Skipping BBR setup.${NC}"
    fi
    ensure_service_user
    download_binary
    configure
    configure_route_rules
    download_geo_assets
    configure_firewall
    create_service
    show_info
}

main
