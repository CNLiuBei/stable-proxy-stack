#!/bin/bash
set -euo pipefail

TARGET_PORT="${1:-443}"
START_PORT="${2:-443}"
END_PORT="${3:-450}"
COMMENT="stable-proxy_hy2_portHopping"

while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q "${COMMENT}"; do
    LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "${COMMENT}" | head -1 | awk '{print $1}')
    iptables -t nat -D PREROUTING "${LINE}"
done

iptables -t nat -A PREROUTING -p udp --dport "${START_PORT}:${END_PORT}" \
    -m comment --comment "${COMMENT}" \
    -j DNAT --to-destination ":${TARGET_PORT}"

echo "Port hopping: UDP ${START_PORT}-${END_PORT} -> ${TARGET_PORT}"
