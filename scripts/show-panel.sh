#!/usr/bin/env bash
# 查询订阅网页地址（快捷命令: ifim-panel）
set -euo pipefail

_script="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _script="$(readlink -f "${_script}" 2>/dev/null || echo "${_script}")"
fi
SCRIPT_DIR="$(cd "$(dirname "${_script}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

CREDS="${INSTALL_DIR}/credentials.txt"
CFG="${WEB_ROOT}/panel/config.json"
NGINX_CONF="/etc/nginx/conf.d/stable-proxy.conf"

panel_url=""
domain=""
proxy_port="443"

if [[ -f "${CREDS}" ]]; then
    # shellcheck source=/dev/null
    source "${CREDS}" 2>/dev/null || true
    panel_url="${PANEL_URL:-}"
    domain="${DOMAIN:-}"
    proxy_port="${PROXY_PORT:-443}"
fi

if [[ -z "${panel_url}" && -f "${CFG}" ]] && command -v jq >/dev/null 2>&1; then
    panel_url=$(jq -r '.panelUrl // empty' "${CFG}")
    domain="${domain:-$(jq -r '.domain // empty' "${CFG}")}"
    proxy_port=$(jq -r '.proxyPort // 443' "${CFG}")
fi

if [[ -z "${panel_url}" && -n "${domain}" && -f "${NGINX_CONF}" ]]; then
    token=$(grep -oE '/s/[a-f0-9]+/' "${NGINX_CONF}" | head -1 | sed 's|^/s/||; s|/$||')
    if [[ -n "${token}" ]]; then
        panel_url="https://${domain}:8443/s/${token}/"
    fi
fi

if [[ -z "${panel_url}" ]]; then
    echo "未找到订阅网页地址。"
    echo "可能尚未安装 IFIM-Proxy，或凭据已删除。"
    echo "安装: bash install.sh"
    exit 1
fi

echo "============================================================"
echo "  IFIM-Proxy 订阅网页"
echo "============================================================"
echo
echo "  ${panel_url}"
echo
[[ -n "${domain}" ]] && echo "  域名:     ${domain}"
echo "  代理端口: ${proxy_port}（Reality TCP + Hy2 UDP）"
echo
echo "  刷新订阅: bash ${INSTALL_DIR}/scripts/regenerate-nodes.sh"
echo "============================================================"
