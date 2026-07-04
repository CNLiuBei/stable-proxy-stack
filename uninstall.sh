#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

if [[ "${1:-}" != "-y" ]]; then
    read -r -p "确认卸载 IFIM-Proxy？此操作不可恢复 [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

echo "Stopping services..."
systemctl disable --now sing-box stable-proxy-port-hopping 2>/dev/null || true

echo "Removing firewall rules..."
while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q "stable-proxy_hy2_portHopping"; do
    LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "stable-proxy_hy2_portHopping" | head -1 | awk '{print $1}')
    iptables -t nat -D PREROUTING "${LINE}"
done

echo "Removing cron jobs..."
(crontab -l 2>/dev/null | grep -vE 'stable-proxy-stack|stable-proxy') | crontab - 2>/dev/null || true

echo "Removing files..."
rm -rf "${INSTALL_DIR}"
rm -rf "${WEB_ROOT}"
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/stable-proxy-port-hopping.service
rm -f /etc/nginx/conf.d/stable-proxy.conf
rm -f /etc/sysctl.d/99-stable-proxy.conf
rm -f /usr/local/bin/sing-box

systemctl daemon-reload
systemctl restart nginx 2>/dev/null || true

echo "Done. TLS certs in ~/.acme.sh were not removed."
echo "Note: UFW rules added during install were not auto-removed."
