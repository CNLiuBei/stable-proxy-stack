#!/usr/bin/env bash
# 从 credentials.txt 重新生成节点链接与 Clash 配置
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

CREDS="${INSTALL_DIR}/credentials.txt"
PANEL_DIR="${WEB_ROOT}/panel"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }
[[ -f "${CREDS}" ]] || { echo "credentials.txt 不存在: ${CREDS}"; exit 1; }

# shellcheck source=/dev/null
source "${CREDS}"

[[ -n "${DOMAIN:-}" && -n "${UUID:-}" && -n "${OBFS_PASSWORD:-}" ]] \
    || { echo "credentials.txt 字段不完整"; exit 1; }

REALITY_DEST="${REALITY_DEST:-dl.google.com}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-6ba85179e30d4fc2}"
PROXY_PORT="${PROXY_PORT:-443}"

# 写回 credentials（补全 PROXY_PORT，移除旧 HY2_PORT_END）
if grep -q '^HY2_PORT_END=' "${CREDS}" 2>/dev/null; then
    sed -i '/^HY2_PORT_END=/d' "${CREDS}"
fi
if grep -q '^PROXY_PORT=' "${CREDS}" 2>/dev/null; then
    sed -i "s/^PROXY_PORT=.*/PROXY_PORT=${PROXY_PORT}/" "${CREDS}"
else
    echo "PROXY_PORT=${PROXY_PORT}" >>"${CREDS}"
fi

REALITY_LINK="vless://${UUID}@${DOMAIN}:${PROXY_PORT}?encryption=none&security=reality&type=tcp&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision#reality-main"
HY2_LINK="hysteria2://${UUID}@${DOMAIN}:${PROXY_PORT}?obfs=salamander&obfs-password=${OBFS_PASSWORD}&peer=${DOMAIN}&insecure=0&sni=${DOMAIN}&alpn=h3#hy2-backup"

cat >"${INSTALL_DIR}/subscribe.txt" <<EOF
# IFIM-Proxy
# Domain: ${DOMAIN}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# [主力·稳定] VLESS + Reality + Vision
${REALITY_LINK}

# [备用·速度] Hysteria2 + obfs · UDP ${PROXY_PORT}
${HY2_LINK}
EOF
chmod 600 "${INSTALL_DIR}/subscribe.txt"

if [[ -f "${INSTALL_DIR}/sub.b64" ]]; then
    printf '%s\n%s' "${REALITY_LINK}" "${HY2_LINK}" | base64 -w0 >"${INSTALL_DIR}/sub.b64"
    chmod 644 "${INSTALL_DIR}/sub.b64"
fi

if [[ -f "${PANEL_DIR}/config.json" ]] && command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg rl "${REALITY_LINK}" --arg hl "${HY2_LINK}" --argjson pp "${PROXY_PORT}" \
        '.realityLink = $rl | .hy2Link = $hl | .proxyPort = $pp' "${PANEL_DIR}/config.json" >"${tmp}"
    mv "${tmp}" "${PANEL_DIR}/config.json"
    chmod 644 "${PANEL_DIR}/config.json"
fi

bash "${SCRIPT_DIR}/port-hopping.sh" --disable
bash "${SCRIPT_DIR}/render-clash.sh"

if [[ -f "${SCRIPT_DIR}/refresh-panel.sh" ]]; then
    bash "${SCRIPT_DIR}/refresh-panel.sh"
else
    echo "节点链接已更新；请运行 refresh-panel.sh 刷新订阅页"
fi

echo "节点已更新（固定端口 ${PROXY_PORT}，无端口跳跃）"
