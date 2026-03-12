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
TARGET_OS=""

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
  --os <name>             指定系统类型：ubuntu|rhel|openwrt|alpine|macos|other
  -h, --help              显示帮助

示例：
  bash install-derper.sh
  curl -fsSL https://your.domain/install-derper.sh | bash
  wget -qO- https://your.domain/install-derper.sh | bash
  # 指定系统类型（可选）：
  bash install-derper.sh --os openwrt
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
    "https://4.ipw.cn"
    "https://ip.sb"
    "https://myip.ipip.net"
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )
  local raw ip
  local tmpf
  tmpf="$(mktemp)"

  for ep in "${endpoints[@]}"; do
    raw="$(download_text "$ep" 2>/dev/null || true)"
    ip="$(echo "$raw" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
    if is_ipv4 "$ip"; then
      echo "$ip" >> "$tmpf"
    fi
  done

  if [[ ! -s "$tmpf" ]]; then
    rm -f "$tmpf"
    return 1
  fi

  # 多数票：同一 IP 出现次数最多的作为结果
  ip="$(sort "$tmpf" | uniq -c | sort -nr | awk 'NR==1{print $2}')"
  rm -f "$tmpf"

  is_ipv4 "$ip" || return 1
  echo "$ip"
  return 0
}

normalize_target_os() {
  case "$1" in
    ubuntu|debian) echo "ubuntu" ;;
    rhel|centos|rocky|alma) echo "rhel" ;;
    openwrt|istoreos) echo "openwrt" ;;
    alpine) echo "alpine" ;;
    macos|darwin) echo "macos" ;;
    other|linux) echo "other" ;;
    *) return 1 ;;
  esac
}

detect_target_os_auto() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || true)"
  if [[ "$uname_s" == "Darwin" ]]; then
    echo "macos"
    return 0
  fi
  if [[ -f /etc/openwrt_release ]] || [[ -d /etc/config ]]; then
    echo "openwrt"
    return 0
  fi
  if [[ -f /etc/alpine-release ]]; then
    echo "alpine"
    return 0
  fi
  if [[ -f /etc/os-release ]]; then
    if grep -Eqi 'ubuntu|debian' /etc/os-release; then
      echo "ubuntu"; return 0
    elif grep -Eqi 'centos|rhel|rocky|almalinux|fedora' /etc/os-release; then
      echo "rhel"; return 0
    fi
  fi
  echo "other"
}

choose_target_os() {
  if [[ -n "$TARGET_OS" ]]; then
    return 0
  fi

  TARGET_OS="$(detect_target_os_auto)"
  log "自动识别系统：$TARGET_OS（可用 --os 覆盖）"
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
    --os)
      TARGET_OS="$(normalize_target_os "${2:-}" || true)"
      [[ -n "$TARGET_OS" ]] || { err "无效 --os 参数: ${2:-}"; exit 1; }
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

choose_target_os
log "系统选择：$TARGET_OS"

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

need_one_cmd curl wget

install_deps() {
  case "$TARGET_OS" in
    ubuntu)
      need_cmd apt
      export DEBIAN_FRONTEND=noninteractive
      log "使用 apt 安装依赖"
      apt update -y
      apt install -y wget git openssl curl ca-certificates tar gzip
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        log "使用 dnf 安装依赖"
        dnf install -y wget git openssl curl ca-certificates tar gzip
      elif command -v yum >/dev/null 2>&1; then
        log "使用 yum 安装依赖"
        yum install -y wget git openssl curl ca-certificates tar gzip
      else
        err "未找到 dnf/yum"
        exit 1
      fi
      ;;
    openwrt)
      need_cmd opkg
      log "使用 opkg 安装依赖"
      opkg update || true
      opkg install wget-ssl ca-bundle ca-certificates openssl-util tar gzip coreutils-nohup procps-ng || true
      ;;
    alpine)
      need_cmd apk
      log "使用 apk 安装依赖"
      apk add --no-cache wget git openssl curl ca-certificates tar gzip bash
      ;;
    macos)
      need_cmd brew
      log "使用 brew 安装依赖"
      brew install curl wget git openssl go || true
      ;;
    other)
      warn "other 模式：跳过自动安装依赖，请确保 curl/wget openssl tar gzip 可用"
      ;;
    *)
      err "未知系统类型: $TARGET_OS"
      exit 1
      ;;
  esac
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

setup_service() {
  if command -v systemctl >/dev/null 2>&1; then
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
      log "derp service is running (systemd)"
    else
      err "derp service failed to start. Check: journalctl -u derp -e"
      exit 1
    fi
    return 0
  fi

  if [[ -d /etc/init.d ]]; then
    log "未检测到 systemd，尝试 OpenWrt/procd 服务模式"
    cat > /etc/init.d/derp <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /etc/derp/derper -hostname derp.myself.com -a :33445 -http-port 33446 -certmode manual -certdir /etc/derp
  procd_set_param respawn
  procd_close_instance
}
EOF
    # 用实际参数替换默认值
    sed -i "s#-hostname derp.myself.com -a :33445 -http-port 33446#-hostname ${DOMAIN} -a :${DERP_PORT} -http-port ${HTTP_PORT}#" /etc/init.d/derp
    chmod +x /etc/init.d/derp
    /etc/init.d/derp enable || true
    /etc/init.d/derp restart || /etc/init.d/derp start
    log "derp service started via /etc/init.d/derp"
    return 0
  fi

  warn "未检测到 systemd/procd，改为后台启动（重启后不会自启）"
  nohup "$BIN_PATH" -hostname "$DOMAIN" -a ":$DERP_PORT" -http-port "$HTTP_PORT" -certmode manual -certdir "$DERP_DIR" >/var/log/derper.log 2>&1 &
  sleep 1
  pgrep -f "$BIN_PATH" >/dev/null 2>&1 || { err "derper 启动失败"; exit 1; }
  log "derp process started (nohup mode)"
}

install_deps
need_cmd openssl

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

  mkdir -p /usr/local
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

setup_service

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
