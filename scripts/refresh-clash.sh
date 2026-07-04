#!/usr/bin/env bash
# 从 credentials.txt 重新生成 Clash Meta 配置（修复后含 2 个节点）
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"
WEB_ROOT="/var/www/stable-proxy"
PANEL_DIR="${WEB_ROOT}/panel"
HY2_PORT_END="${HY2_PORT_END:-450}"
REALITY_DEST="${REALITY_DEST:-dl.google.com}"

[[ -f "${INSTALL_DIR}/credentials.txt" ]] || { echo "credentials.txt 不存在"; exit 1; }

# shellcheck source=/dev/null
source "${INSTALL_DIR}/credentials.txt"

[[ -n "${DOMAIN:-}" && -n "${UUID:-}" && -n "${OBFS_PASSWORD:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] \
    || { echo "credentials.txt 字段不完整"; exit 1; }

cat >"${INSTALL_DIR}/clash-meta.yaml" <<EOF
# Clash Meta / Mihomo profile — 含 Reality + Hysteria2 两个节点
proxies:
  - name: reality-main
    type: vless
    server: ${DOMAIN}
    port: 443
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: 6ba85179e30d4fc2
    client-fingerprint: chrome
  - name: hy2-backup
    type: hysteria2
    server: ${DOMAIN}
    ports: 443-${HY2_PORT_END}
    hop-interval: 30
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
echo "已更新: ${PANEL_DIR}/clash.yaml（reality-main + hy2-backup）"
