#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"

echo "Stopping services..."
systemctl disable --now sing-box stable-proxy-port-hopping 2>/dev/null || true

echo "Removing firewall rules..."
while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q "stable-proxy_hy2_portHopping"; do
    LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "stable-proxy_hy2_portHopping" | head -1 | awk '{print $1}')
    iptables -t nat -D PREROUTING "${LINE}"
done

echo "Removing files..."
rm -rf "${INSTALL_DIR}"
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/stable-proxy-port-hopping.service
rm -f /etc/nginx/conf.d/stable-proxy.conf
rm -f /etc/sysctl.d/99-stable-proxy.conf
rm -f /usr/local/bin/sing-box

systemctl daemon-reload
systemctl restart nginx 2>/dev/null || true

echo "Done. TLS certs in ~/.acme.sh were not removed."
