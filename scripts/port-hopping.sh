#!/bin/bash
# 移除旧版 Hy2 UDP 端口跳跃规则（现改为固定 443，不再使用跳跃）
set -euo pipefail

COMMENT="stable-proxy_hy2_portHopping"

disable_port_hopping() {
    while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q "${COMMENT}"; do
        LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "${COMMENT}" | head -1 | awk '{print $1}')
        iptables -t nat -D PREROUTING "${LINE}"
    done

    if systemctl is-enabled stable-proxy-port-hopping.service >/dev/null 2>&1 \
        || systemctl is-active stable-proxy-port-hopping.service >/dev/null 2>&1; then
        systemctl disable --now stable-proxy-port-hopping.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/stable-proxy-port-hopping.service
    systemctl daemon-reload 2>/dev/null || true

    echo "Hy2 端口跳跃已禁用（固定 UDP 443）"
}

case "${1:-}" in
    --disable|disable) disable_port_hopping ;;
    -h|--help)
        echo "用法: bash port-hopping.sh [--disable]"
        echo "  --disable  移除 iptables 跳跃规则并停用相关 systemd 服务"
        ;;
    *)
        disable_port_hopping
        ;;
esac
