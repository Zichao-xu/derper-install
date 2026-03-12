# derper-install

一键安装/卸载 Tailscale DERP 脚本（Linux 优先，适配 OpenWrt、Ubuntu 等）。

One-click install/uninstall scripts for Tailscale DERP (Linux-first, supports OpenWrt, Ubuntu, etc.).

## 核心优势（Key Advantage）

- **无需域名、无需备案，也可以快速搭建 DERP 中转。**
- **No domain name or ICP filing required** to quickly set up your own DERP relay.

> 默认方案使用自签证书 + `InsecureForTests`，适合自用/测试场景。
> The default path uses self-signed cert + `InsecureForTests`, ideal for personal/test usage.

---

## 安装（Install）

### 一键安装命令（One-liner）

```bash
curl -fsSL https://raw.githubusercontent.com/Zichao-xu/derper-install/main/install-derper.sh | bash
```

### 可选参数（Optional flags）

```bash
# 示例：手动指定公网 IP、端口、区域信息
curl -fsSL https://raw.githubusercontent.com/Zichao-xu/derper-install/main/install-derper.sh | bash -s -- \
  --server-ip 1.2.3.4 \
  --derp-port 33445 \
  --http-port 33446 \
  --region-id 901 \
  --region-code Myself \
  --region-name "Myself Derper" \
  --node-name 901a
```

支持参数 / Supported flags:

- `--domain` DERP 证书域名（默认 `derp.myself.com`） / DERP cert hostname (default `derp.myself.com`)
- `--server-ip` 手动指定 derpMap 的公网 IPv4 / Override public IPv4 in derpMap
- `--derp-port` DERP 端口（默认 `33445`） / DERP port (default `33445`)
- `--http-port` HTTP/调试端口（默认 `33446`） / HTTP/debug port (default `33446`)
- `--region-id` 区域 ID / Region ID
- `--region-code` 区域代码 / Region code
- `--region-name` 区域名称 / Region name
- `--node-name` 节点名 / Node name
- `--skip-go-install` 跳过 Go 安装 / Skip Go install
- `--os` 强制指定系统类型（`ubuntu|rhel|openwrt|alpine|other`） / Force OS strategy

---

## 卸载（Uninstall）

### 一键卸载命令（One-liner）

```bash
curl -fsSL https://raw.githubusercontent.com/Zichao-xu/derper-install/main/uninstall-derper.sh | bash
```

### 彻底清理（Purge all）

```bash
curl -fsSL https://raw.githubusercontent.com/Zichao-xu/derper-install/main/uninstall-derper.sh | bash -s -- --purge-all -y
```

- `--purge-all` 删除 `/etc/derp` 全部内容（证书、derpMap）
- `-y` 跳过确认

---

## 防火墙端口（Firewall ports）

请确保放行 / Please allow:

- `TCP 33445`（DERP）
- `UDP 3478`（STUN）
- `TCP 33446`（HTTP/debug，可选 / optional）

---

## 说明（Notes）

- 脚本会自动识别系统并选择对应策略。  
  Script auto-detects the OS and applies matching strategy.
- 如 `raw.githubusercontent.com` 不稳定，可换镜像源下载后执行。  
  If `raw.githubusercontent.com` is unstable, use a mirror source.
