#!/usr/bin/env bash
set -euo pipefail

# One-click DERP installer
# Usage examples:
#   bash install-derper.sh
#   curl -fsSL https://your.domain/install-derper.sh | bash

DERP_DIR="/etc/derp"
BIN_PATH="${DERP_DIR}/derper"
SERVICE_PATH="/etc/systemd/system/derp.service"

DOMAIN="derp.myself.com"
SERVER_IP=""
DERP_PORT="33445"
HTTP_PORT="33446"
REGION_ID="901"
REGION_CODE="Myself"
REGION_NAME="Myself Derper"
NODE_NAME="901a"
SKIP_GO_INSTALL="false"

log() { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
err() { echo -e "[x] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

usage() {
  cat <<'EOF'
安装 Tailscale DERP 服务

必填参数：
  无

可选参数：
  --domain <FQDN>         DERP 域名（默认 derp.myself.com）
  --server-ip <IPv4>      手动指定 derpMap 使用的公网 IPv4（默认自动探测）
  --derp-port <port>      DERP 端口（默认 33445）
  --http-port <port>      DERP HTTP/调试端口（默认 33446）
  --region-id <id>        derpMap RegionID（默认 901）
  --region-code <code>    derpMap RegionCode（默认 Myself）
  --region-name <name>    derpMap RegionName（默认 Myself Derper）
  --node-name <name>      derpMap 节点名（默认 901a）
  --skip-go-install       跳过 Go 安装/更新
  -h, --help              显示帮助

示例：
  bash install-derper.sh
  curl -fsSL https://your.domain/install-derper.sh | bash
  # 如需覆盖默认域名：
  bash install-derper.sh --domain derp.example.com
EOF
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do
    (( n >= 0 && n <= 255 )) || return 1
  done
  return 0
}

detect_public_ip() {
  local endpoints=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )
  local ip
  for ep in "${endpoints[@]}"; do
    ip="$(curl -4fsSL --max-time 8 "$ep" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --server-ip) SERVER_IP="${2:-}"; shift 2 ;;
    --derp-port) DERP_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --region-id) REGION_ID="${2:-}"; shift 2 ;;
    --region-code) REGION_CODE="${2:-}"; shift 2 ;;
    --region-name) REGION_NAME="${2:-}"; shift 2 ;;
    --node-name) NODE_NAME="${2:-}"; shift 2 ;;
    --skip-go-install) SKIP_GO_INSTALL="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "Please run as root (or use sudo)."
  exit 1
fi

if [[ -n "$SERVER_IP" ]]; then
  if ! is_ipv4 "$SERVER_IP"; then
    err "--server-ip is not a valid IPv4: $SERVER_IP"
    exit 1
  fi
  log "Using user-provided public IPv4: $SERVER_IP"
else
  log "Detecting server public IPv4 automatically"
  SERVER_IP="$(detect_public_ip || true)"
  if [[ -z "$SERVER_IP" ]]; then
    err "Failed to auto-detect public IPv4. You can pass --server-ip manually."
    exit 1
  fi
  log "Detected public IPv4: $SERVER_IP"
fi

need_cmd apt
need_cmd systemctl
need_cmd openssl
need_cmd curl
need_cmd git

export DEBIAN_FRONTEND=noninteractive
log "Updating apt packages"
apt update -y
apt install -y wget git openssl curl ca-certificates

if [[ "$SKIP_GO_INSTALL" != "true" ]]; then
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) GO_ARCH="amd64" ;;
    arm64) GO_ARCH="arm64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  log "Detecting latest Go version"
  GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [[ "$GO_VERSION" =~ ^go[0-9] ]] || { err "Failed to detect Go version"; exit 1; }

  GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  GO_URL="https://go.dev/dl/${GO_TARBALL}"

  log "Installing ${GO_VERSION} (${GO_ARCH})"
  wget -q -O "/tmp/${GO_TARBALL}" "$GO_URL"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
  rm -f "/tmp/${GO_TARBALL}"
fi

export PATH="/usr/local/go/bin:${PATH}"
need_cmd go

log "Configuring Go env"
go env -w GO111MODULE=on
# Use default proxy chain; keep direct fallback
GO_PROXY_DEFAULT="https://proxy.golang.org,direct"
go env -w GOPROXY="$GO_PROXY_DEFAULT"

log "Installing derper binary"
go install tailscale.com/cmd/derper@main

DERPER_SRC_BIN="$(go env GOPATH)/bin/derper"
[[ -x "$DERPER_SRC_BIN" ]] || { err "derper binary not found after go install"; exit 1; }

mkdir -p "$DERP_DIR"
install -m 0755 "$DERPER_SRC_BIN" "$BIN_PATH"

CRT_PATH="${DERP_DIR}/${DOMAIN}.crt"
KEY_PATH="${DERP_DIR}/${DOMAIN}.key"

log "Generating self-signed cert for ${DOMAIN}"
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "$KEY_PATH" \
  -out "$CRT_PATH" \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1

log "Writing systemd service"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=TS Derper
After=network.target
Wants=network.target

[Service]
User=root
Restart=always
RestartSec=3
ExecStart=${BIN_PATH} -hostname ${DOMAIN} -a :${DERP_PORT} -http-port ${HTTP_PORT} -certmode manual -certdir ${DERP_DIR}
RestartPreventExitStatus=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable derp >/dev/null
systemctl restart derp

if systemctl is-active --quiet derp; then
  log "derp service is running"
else
  err "derp service failed to start. Check: journalctl -u derp -e"
  exit 1
fi

DERPMAP_FILE="${DERP_DIR}/derpmap-${DOMAIN}.jsonc"
cat > "$DERPMAP_FILE" <<EOF
"derpMap": {
  "OmitDefaultRegions": true,
  "Regions": {
    "${REGION_ID}": {
      "RegionID": ${REGION_ID},
      "RegionCode": "${REGION_CODE}",
      "RegionName": "${REGION_NAME}",
      "Nodes": [
        {
          "Name": "${NODE_NAME}",
          "RegionID": ${REGION_ID},
          "DERPPort": ${DERP_PORT},
          "IPv4": "${SERVER_IP}",
          "InsecureForTests": true
        }
      ]
    }
  }
}
EOF

log "安装完成"
echo
echo "================ 请复制下面 derpMap 到浏览器管理界面 ================"
cat "$DERPMAP_FILE"
echo "======================================================================="
echo
echo "文件已保存：$DERPMAP_FILE"
echo "查看服务状态：systemctl status derp --no-pager"
echo "查看实时日志：journalctl -u derp -f"
echo
echo "[重要] 请在云服务器安全组/防火墙放行以下端口："
echo "  - TCP ${DERP_PORT}  （DERP）"
echo "  - UDP 3478         （STUN）"
echo "  - TCP ${HTTP_PORT}  （DERP HTTP/调试端口，可选对外开放）"
echo
echo "如果你使用 UFW，可执行："
echo "  ufw allow ${DERP_PORT}/tcp"
echo "  ufw allow 3478/udp"
echo "  ufw allow ${HTTP_PORT}/tcp"
