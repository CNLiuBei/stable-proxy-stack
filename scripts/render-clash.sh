#!/usr/bin/env bash
# 从 credentials.txt 生成 Clash Meta 配置
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

PANEL_DIR="${WEB_ROOT}/panel"
CREDS="${INSTALL_DIR}/credentials.txt"

[[ -f "${CREDS}" ]] || { echo "credentials.txt 不存在: ${CREDS}"; exit 1; }

# shellcheck source=/dev/null
source "${CREDS}"

[[ -n "${DOMAIN:-}" && -n "${UUID:-}" && -n "${OBFS_PASSWORD:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] \
    || { echo "credentials.txt 字段不完整"; exit 1; }

REALITY_DEST="${REALITY_DEST:-dl.google.com}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-6ba85179e30d4fc2}"
PROXY_PORT="${PROXY_PORT:-443}"

cat >"${INSTALL_DIR}/clash-meta.yaml" <<EOF
# Clash Meta / Mihomo profile — 含 Reality + Hysteria2 两个节点
proxies:
  - name: reality-main
    type: vless
    server: ${DOMAIN}
    port: ${PROXY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}
    client-fingerprint: chrome
  - name: hy2-backup
    type: hysteria2
    server: ${DOMAIN}
    port: ${PROXY_PORT}
    password: ${UUID}
    obfs: salamander
    obfs-password: ${OBFS_PASSWORD}
    sni: ${DOMAIN}
    skip-cert-verify: false
    alpn:
      - h3

proxy-groups:
  - name: stable-proxy
    type: select
    proxies:
      - reality-main
      - hy2-backup

rules:
  - MATCH,stable-proxy
EOF

mkdir -p "${PANEL_DIR}"
cp "${INSTALL_DIR}/clash-meta.yaml" "${PANEL_DIR}/clash.yaml"
chmod 644 "${PANEL_DIR}/clash.yaml" "${INSTALL_DIR}/clash-meta.yaml"
echo "已更新: ${PANEL_DIR}/clash.yaml（reality-main + hy2-backup，端口 ${PROXY_PORT}）"
