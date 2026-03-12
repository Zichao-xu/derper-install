#!/usr/bin/env bash
set -euo pipefail

# One-click DERP installer
# Usage examples:
#   bash install-derper.sh
#   curl -fsSL https://your.domain/install-derper.sh | bash
#   wget -qO- https://your.domain/install-derper.sh | bash

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

need_one_cmd() {
  local ok="false"
  for c in "$@"; do
    if command -v "$c" >/dev/null 2>&1; then
      ok="true"
      break
    fi
  done
  [[ "$ok" == "true" ]] || { err "Missing command (one of): $*"; exit 1; }
}

download_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 8 --retry 2 --retry-delay 1 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=10 --tries=2 "$url"
  else
    return 1
  fi
}

download_file() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 10 --retry 3 --retry-delay 1 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" --timeout=15 --tries=3 "$url"
  else
    return 1
  fi
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
  wget -qO- https://your.domain/install-derper.sh | bash
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
    "https://ip.sb"
    "https://4.ipw.cn"
  )
  local ip
  for ep in "${endpoints[@]}"; do
    ip="$(download_text "$ep" 2>/dev/null | tr -d '[:space:]' || true)"
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

need_cmd systemctl
need_cmd openssl
need_one_cmd curl wget

install_deps() {
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    log "检测到 apt，安装依赖中"
    apt update -y
    apt install -y wget git openssl curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    log "检测到 dnf，安装依赖中"
    dnf install -y wget git openssl curl ca-certificates tar gzip
  elif command -v yum >/dev/null 2>&1; then
    log "检测到 yum，安装依赖中"
    yum install -y wget git openssl curl ca-certificates tar gzip
  elif command -v apk >/dev/null 2>&1; then
    log "检测到 apk，安装依赖中"
    apk add --no-cache wget git openssl curl ca-certificates tar gzip bash
  else
    err "不支持的包管理器（需要 apt/dnf/yum/apk 之一）"
    exit 1
  fi
}

map_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv6l" ;;
    i386|i686) echo "386" ;;
    riscv64) echo "riscv64" ;;
    *) return 1 ;;
  esac
}

install_deps

if [[ "$SKIP_GO_INSTALL" != "true" ]]; then
  GO_ARCH="$(map_go_arch || true)"
  if [[ -z "$GO_ARCH" ]]; then
    err "不支持的架构: $(uname -m)"
    exit 1
  fi

  log "探测最新 Go 版本"
  GO_VERSION="$(download_text 'https://go.dev/VERSION?m=text' | head -n1 || true)"
  if [[ ! "$GO_VERSION" =~ ^go[0-9] ]]; then
    GO_VERSION="$(download_text 'https://golang.google.cn/VERSION?m=text' | head -n1 || true)"
  fi
  [[ "$GO_VERSION" =~ ^go[0-9] ]] || { err "无法获取 Go 版本，请检查网络"; exit 1; }

  GO_TARBALL="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  GO_URLS=(
    "https://go.dev/dl/${GO_TARBALL}"
    "https://golang.google.cn/dl/${GO_TARBALL}"
  )

  log "安装 ${GO_VERSION} (${GO_ARCH})"
  GO_OK="false"
  for u in "${GO_URLS[@]}"; do
    log "尝试下载：$u"
    if download_file "$u" "/tmp/${GO_TARBALL}"; then
      GO_OK="true"
      break
    fi
    warn "下载失败，切换镜像"
  done
  [[ "$GO_OK" == "true" ]] || { err "Go 下载失败，请稍后重试"; exit 1; }

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
  rm -f "/tmp/${GO_TARBALL}"
fi

export PATH="/usr/local/go/bin:${PATH}"
need_cmd go

log "Configuring Go env"
go env -w GO111MODULE=on
# 国内网络优先 goproxy.cn，并保留 direct 回退
GO_PROXY_DEFAULT="https://goproxy.cn,https://proxy.golang.org,direct"
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
echo
echo "如果 curl 拉不下来，可改用："
echo "  wget -qO- <你的脚本链接> | bash"
