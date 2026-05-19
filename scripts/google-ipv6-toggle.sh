#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-v2bx}"
INSTALL_DIR="${INSTALL_DIR:-/etc/V2bX}"
BASE_CONFIG="${BASE_CONFIG:-$INSTALL_DIR/config.json}"
BIN_PATH="${BIN_PATH:-$INSTALL_DIR/V2bX}"
RUN_ROOT="${RUN_ROOT:-/run/V2bX/google-ipv6}"
RUNTIME_CONFIG="$RUN_ROOT/config.json"
RUNTIME_ROUTE="$RUN_ROOT/route.json"
RUNTIME_OUTBOUNDS="$RUN_ROOT/outbounds.json"
DROPIN_DIR="${DROPIN_DIR:-/etc/systemd/system/$SERVICE_NAME.service.d}"
DROPIN_FILE="$DROPIN_DIR/90-google-ipv6.conf"
DOMAIN_RULE="${DOMAIN_RULE:-geosite:google}"
OUTBOUND_TAG="${OUTBOUND_TAG:-direct-v6}"
DOMAIN_STRATEGY="${DOMAIN_STRATEGY:-UseIPv6}"
CHECK_URL="${CHECK_URL:-https://api64.ipify.org}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-6}"

usage() {
    cat <<EOF
Usage:
  $0 enable
  $0 disable
  $0 status
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

need_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "run as root"
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

check_prereqs() {
    have_cmd systemctl || die "systemctl not found"
    have_cmd ip || die "ip not found"
    have_cmd sysctl || die "sysctl not found"
    [ -x "$BIN_PATH" ] || die "missing binary: $BIN_PATH"
    [ -f "$BASE_CONFIG" ] || die "missing base config: $BASE_CONFIG"
    [ -f "$INSTALL_DIR/route.json" ] || die "missing original route file: $INSTALL_DIR/route.json"
    [ -f "$INSTALL_DIR/outbounds.json" ] || die "missing original outbounds file: $INSTALL_DIR/outbounds.json"
}

check_ipv6() {
    local disabled route addr public_ok

    disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
    [ "$disabled" = "0" ] || die "IPv6 is disabled in sysctl"

    route="$(ip -6 route show default 2>/dev/null || true)"
    [ -n "$route" ] || die "no IPv6 default route"

    addr="$(ip -6 addr show scope global up 2>/dev/null || true)"
    printf '%s' "$addr" | grep -q 'inet6 ' || die "no global IPv6 address"

    public_ok="false"
    if have_cmd curl; then
        if curl -6 -fsS --connect-timeout "$CHECK_TIMEOUT" --max-time "$((CHECK_TIMEOUT + 4))" "$CHECK_URL" >/dev/null; then
            public_ok="true"
        fi
    elif have_cmd wget; then
        if wget -6 -q --timeout="$CHECK_TIMEOUT" -O /dev/null "$CHECK_URL"; then
            public_ok="true"
        fi
    else
        log "Warning: no curl/wget found, skipping public IPv6 check"
        public_ok="true"
    fi

    [ "$public_ok" = "true" ] || die "public IPv6 connectivity check failed"
}

pick_python() {
    if have_cmd python3; then
        printf '%s\n' python3
        return
    fi
    if have_cmd python; then
        printf '%s\n' python
        return
    fi
    die "python3 or python is required"
}

write_runtime_files() {
    mkdir -p "$RUN_ROOT"

    local py
    py="$(pick_python)"

    "$py" - "$BASE_CONFIG" "$RUNTIME_CONFIG" "$RUNTIME_ROUTE" "$RUNTIME_OUTBOUNDS" "$DOMAIN_RULE" "$OUTBOUND_TAG" "$DOMAIN_STRATEGY" <<'PY'
import copy
import json
import os
import pathlib
import sys

base_config_path = pathlib.Path(sys.argv[1])
runtime_config_path = pathlib.Path(sys.argv[2])
runtime_route_path = pathlib.Path(sys.argv[3])
runtime_outbounds_path = pathlib.Path(sys.argv[4])
domain_rule = sys.argv[5]
outbound_tag = sys.argv[6]
domain_strategy = sys.argv[7]

base_config = json.loads(base_config_path.read_text(encoding="utf-8"))
cores = base_config.get("Cores") or []
if not isinstance(cores, list) or not cores:
    raise SystemExit("base config has no cores")

first_xray = None
for core in cores:
    if isinstance(core, dict) and core.get("Type") == "xray":
        first_xray = core
        break

if first_xray is None:
    raise SystemExit("base config has no xray core")

route_src = pathlib.Path(first_xray.get("RouteConfigPath") or os.path.join(str(base_config_path.parent), "route.json"))
outbound_src = pathlib.Path(first_xray.get("OutboundConfigPath") or os.path.join(str(base_config_path.parent), "outbounds.json"))

route = json.loads(route_src.read_text(encoding="utf-8"))
rules = route.get("rules")
if not isinstance(rules, list):
    rules = []

google_rule = {
    "type": "field",
    "domain": [domain_rule],
    "outboundTag": outbound_tag,
}
if not any(isinstance(rule, dict) and rule.get("domain") == [domain_rule] and rule.get("outboundTag") == outbound_tag for rule in rules):
    rules = [google_rule] + rules
route["rules"] = rules

outbounds = json.loads(outbound_src.read_text(encoding="utf-8"))
if not any(isinstance(item, dict) and item.get("tag") == outbound_tag for item in outbounds):
    outbounds.append({
        "tag": outbound_tag,
        "protocol": "freedom",
        "settings": {
            "domainStrategy": domain_strategy
        }
    })

runtime_config = copy.deepcopy(base_config)
for core in runtime_config.get("Cores", []):
    if isinstance(core, dict) and core.get("Type") == "xray":
        core["RouteConfigPath"] = str(runtime_route_path)
        core["OutboundConfigPath"] = str(runtime_outbounds_path)

def write(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(data, encoding="utf-8")
    os.replace(tmp, path)

write(runtime_route_path, json.dumps(route, ensure_ascii=False, indent=2) + "\n")
write(runtime_outbounds_path, json.dumps(outbounds, ensure_ascii=False, indent=2) + "\n")
write(runtime_config_path, json.dumps(runtime_config, ensure_ascii=False, indent=2) + "\n")
PY

    chown root:root "$RUN_ROOT" "$RUNTIME_CONFIG" "$RUNTIME_ROUTE" "$RUNTIME_OUTBOUNDS"
    chmod 0750 "$RUN_ROOT"
    chmod 0640 "$RUNTIME_CONFIG" "$RUNTIME_ROUTE" "$RUNTIME_OUTBOUNDS"
}

write_dropin() {
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN_FILE" <<EOF
[Service]
ExecStart=
ExecStart=$BIN_PATH server -c $RUNTIME_CONFIG
EOF
}

enable_mode() {
    check_prereqs
    check_ipv6
    write_runtime_files
    write_dropin
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    log "enabled"
}

disable_mode() {
    check_prereqs
    rm -f "$DROPIN_FILE"
    rm -rf "$RUN_ROOT"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    log "disabled"
}

status_mode() {
    if [ -f "$DROPIN_FILE" ]; then
        log "enabled"
    else
        log "disabled"
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "service: active"
    else
        log "service: inactive"
    fi
}

main() {
    need_root
    case "${1:-}" in
        enable) enable_mode ;;
        disable) disable_mode ;;
        status) status_mode ;;
        -h|--help|"") usage ;;
        *) die "unknown command: $1" ;;
    esac
}

main "$@"
