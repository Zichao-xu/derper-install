#!/usr/bin/env bash
set -euo pipefail

DERP_DIR="/etc/derp"
BIN_PATH="${DERP_DIR}/derper"
SYSTEMD_SERVICE="/etc/systemd/system/derp.service"
INITD_SERVICE="/etc/init.d/derp"
LOG_PATH="/var/log/derper.log"

PURGE_ALL="false"
FORCE_YES="false"

log() { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
err() { echo -e "[x] $*" >&2; }

usage() {
  cat <<'EOF'
卸载 DERP 脚本

参数：
  --purge-all    额外删除 /etc/derp 下全部文件（证书、derpmap 等）
  -y, --yes      跳过确认
  -h, --help     显示帮助

示例：
  bash uninstall-derper.sh
  bash uninstall-derper.sh --purge-all -y
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-all) PURGE_ALL="true"; shift ;;
    -y|--yes) FORCE_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "请使用 root 运行（或通过 sudo）。"
  exit 1
fi

if [[ "$FORCE_YES" != "true" ]]; then
  echo "将执行以下操作："
  echo "  1) 停止并移除 derp 服务（systemd 或 init.d）"
  echo "  2) 删除 derper 二进制（${BIN_PATH}）"
  if [[ "$PURGE_ALL" == "true" ]]; then
    echo "  3) 删除 ${DERP_DIR} 下全部文件（包含证书和 derpMap）"
  else
    echo "  3) 保留 ${DERP_DIR} 下证书/配置文件（仅删除 derper 二进制）"
  fi
  printf "确认继续？[y/N]: "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log "已取消。"; exit 0 ;;
  esac
fi

# 1) systemd
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^derp\.service'; then
    log "检测到 systemd 服务 derp，停止并禁用"
    systemctl stop derp || true
    systemctl disable derp || true
  fi
  if [[ -f "$SYSTEMD_SERVICE" ]]; then
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload || true
    log "已删除：$SYSTEMD_SERVICE"
  fi
fi

# 2) init.d / procd
if [[ -f "$INITD_SERVICE" ]]; then
  log "检测到 init.d 服务 derp，停止并移除"
  "$INITD_SERVICE" stop || true
  "$INITD_SERVICE" disable || true
  rm -f "$INITD_SERVICE"
  log "已删除：$INITD_SERVICE"
fi

# 3) 杀残留进程
if pgrep -f '/etc/derp/derper' >/dev/null 2>&1; then
  warn "发现残留 derper 进程，尝试终止"
  pkill -f '/etc/derp/derper' || true
fi

# 4) 删除二进制与日志
if [[ -f "$BIN_PATH" ]]; then
  rm -f "$BIN_PATH"
  log "已删除：$BIN_PATH"
fi

if [[ -f "$LOG_PATH" ]]; then
  rm -f "$LOG_PATH"
  log "已删除日志：$LOG_PATH"
fi

# 5) 清理目录
if [[ "$PURGE_ALL" == "true" ]]; then
  if [[ -d "$DERP_DIR" ]]; then
    rm -rf "$DERP_DIR"
    log "已删除目录：$DERP_DIR"
  fi
else
  # 尝试删除空目录
  if [[ -d "$DERP_DIR" ]]; then
    rmdir "$DERP_DIR" 2>/dev/null || true
  fi
fi

log "DERP 卸载完成。"
if [[ "$PURGE_ALL" != "true" ]]; then
  warn "证书与 derpMap 可能仍保留在 ${DERP_DIR}。如需彻底删除，请加 --purge-all。"
fi
