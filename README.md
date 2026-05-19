# V2bX Private Lite

This is a private lite build of V2bX for Xboard/V2board UniProxy deployments.

It intentionally keeps only the path used by this project:

- Xboard/V2board UniProxy API
- VLESS nodes
- Xray core
- default local block rules for BT, private IP, China IP, and China domains
- Reality and VLESS transport options from the panel
- user sync, traffic report, online IP report, routing block rules, and speed/device limits

It is not a drop-in replacement for upstream V2bX.

## Supported

- Core: `xray`
- Node type: `vless`
- API paths:
  - `/api/v1/server/UniProxy/config`
  - `/api/v1/server/UniProxy/user`
  - `/api/v1/server/UniProxy/alivelist`
  - `/api/v1/server/UniProxy/push`
  - `/api/v1/server/UniProxy/alive`

## Not Included

The following upstream V2bX features are intentionally not part of this lite build:

- sing-box core
- Hysteria/Hysteria2
- Trojan
- Shadowsocks
- VMess
- AnyTLS/TUIC
- ACME certificate automation
- generic multi-panel compatibility

## Build

```bash
go test ./...
go build -o V2bX .
```

On Windows or restricted environments, set `GOCACHE` to a writable directory if the default Go cache is not writable.

## Run

```bash
./V2bX server -c ./config.example.json
```

For production, copy `config.example.json` to `/etc/V2bX/config.json` and set the real panel host, API key, and node id.

## Install

The installer requires configuration through environment variables. It no longer embeds private panel credentials.

```bash
API_HOST=https://panel.example.com \
API_KEY=your_uniproxy_api_key \
DOWNLOAD_BASE=https://download.example.com \
bash install.sh 1
```

Or deploy directly from GitHub with release binaries:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/miliyao/phantom-node/main/install.sh) \
  --node-id=1 \
  --panel=https://panel.example.com \
  --token=your_uniproxy_api_key
```

Multiple node ids can be deployed with one config:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/miliyao/phantom-node/main/install.sh) \
  --node-id=1,2 \
  --panel=https://panel.example.com \
  --token=your_uniproxy_api_key
```

`DOWNLOAD_BASE` must contain these files:

- `v2bx-linux-amd64`
- `v2bx-linux-arm64`

Optional variables:

- `INSTALL_DIR`, default `/etc/V2bX`
- `SERVICE_NAME`, default `v2bx`
- `NODE_TYPE`, default `vless`
- `TIMEZONE`, default `Asia/Shanghai`

The installer sets the system timezone to `Asia/Shanghai` by default. Override it with `--timezone=UTC` or another valid timezone when needed.

The installer writes default node-level route protection files on first install:

- `/etc/V2bX/outbounds.json`: defines `direct` freedom first, then the `block` blackhole outbound
- `/etc/V2bX/route.json`: uses `IPIfNonMatch` and blocks BitTorrent, private IP ranges, `geoip:cn`, `geosite:cn`, and `geosite:category-ads-all`
- `/etc/V2bX/dns.json`: uses `8.8.8.8` and `1.1.1.1` as a minimal DNS fallback
- `/etc/V2bX/geoip.dat` and `/etc/V2bX/geosite.dat`: downloaded automatically for `geoip:` and `geosite:` rules

The installer also creates a dedicated `v2bx` system user and applies conservative owner-based iptables hardening by default:

- rejects ICMP sent by the `v2bx` process

Use `--no-firewall` to skip iptables rules. TCP outbound port allowlists are intentionally not installed because they can break proxy server replies to client ephemeral ports.

Existing `route.json` and `outbounds.json` files are kept, so custom rules are not overwritten on reinstall.

## Minimal Config

See `config.example.json`.

The `Nodes` item may either keep `ApiHost`, `ApiKey`, `NodeID`, and `NodeType` at the top level, or split them into `ApiConfig` and `Options`.

## Notes

- DNS pushed by the panel is applied only when Xray `DnsConfigPath` is configured.
- This repository may include release binaries for private deployment convenience, but source-based builds should use `go build`.
- Keep API keys out of committed scripts and public logs.
