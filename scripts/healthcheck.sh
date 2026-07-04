#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

STAMP="/run/stable-proxy-healthcheck.stamp"
COOLDOWN=900

if [[ -f "${STAMP}" ]]; then
    last=$(stat -c %Y "${STAMP}" 2>/dev/null || stat -f %m "${STAMP}" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( now - last < COOLDOWN )); then
        exit 0
    fi
fi

needs_restart=false
if ! systemctl is-active --quiet sing-box.service; then
    needs_restart=true
elif ! ss -tlnpH 'sport = :443' 2>/dev/null | grep -q sing-box; then
    needs_restart=true
fi

if [[ "${needs_restart}" == true ]]; then
    touch "${STAMP}"
    systemctl restart sing-box.service
    logger "IFIM-Proxy: sing-box restarted by healthcheck"
fi
