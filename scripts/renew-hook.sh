#!/bin/bash
INSTALL_DIR="/etc/stable-proxy-stack"
if nginx -t 2>/dev/null; then
    systemctl reload nginx
fi
if [[ -f "${INSTALL_DIR}/sing-box/sing-box" ]]; then
    systemctl restart sing-box.service
fi
