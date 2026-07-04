#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
fi

if [[ -f "${INSTALL_DIR}/sing-box/sing-box" ]]; then
    systemctl restart sing-box.service 2>/dev/null || true
fi
