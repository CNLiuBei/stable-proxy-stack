#!/usr/bin/env bash
# Dry-run validation — does NOT install or modify system services
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

ok()   { echo "[OK] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

echo "=== stable-proxy-stack dry-run test ==="

bash -n "${SCRIPT_DIR}/install.sh" && ok "install.sh syntax"
grep -q '^SCRIPT_VERSION="0.0.2"' "${SCRIPT_DIR}/install.sh" && ok "SCRIPT_VERSION 0.0.2" || fail "SCRIPT_VERSION"
bash "${SCRIPT_DIR}/install.sh" --version 2>/dev/null | grep -q 'v0.0.2' && ok "install.sh --version" || fail "install.sh --version"
bash -n "${SCRIPT_DIR}/uninstall.sh" && ok "uninstall.sh syntax"
for s in scripts/*.sh; do bash -n "$s" && ok "$(basename "$s") syntax"; done

ARCH=$(uname -m)
case "${ARCH}" in x86_64) SB_ARCH="amd64" ;; aarch64) SB_ARCH="arm64" ;; *) SB_ARCH="amd64" ;; esac
VER="1.13.14"
TMP=/tmp/sb-test-$$
mkdir -p "$TMP"
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz" \
    | tar -xzf - -C "$TMP"
SB="$TMP/sing-box-${VER}-linux-${SB_ARCH}/sing-box"
[[ -x "$SB" ]] && ok "sing-box download (${VER}/${SB_ARCH})" || fail "sing-box download"

KEYS=$("$SB" generate reality-keypair)
PRIV=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
PUB=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
[[ -n "$PRIV" && -n "$PUB" ]] && ok "reality keypair generation" || fail "reality keypair"

UUID=$(cat /proc/sys/kernel/random/uuid)
OBFS=$(openssl rand -hex 8)
cat >"$TMP/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 443,
      "ignore_client_bandwidth": true,
      "obfs": {"type": "salamander", "password": "${OBFS}"},
      "users": [{"name": "test", "password": "${UUID}"}],
      "tls": {
        "enabled": true,
        "server_name": "test.example.com",
        "alpn": ["h3"],
        "certificate_path": "/etc/ssl/certs/ssl-cert-snakeoil.pem",
        "key_path": "/etc/ssl/private/ssl-cert-snakeoil.key"
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "tag": "VLESSReality",
      "users": [{"name": "test", "uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "dl.google.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "dl.google.com", "server_port": 443},
          "private_key": "${PRIV}",
          "short_id": ["", "6ba85179e30d4fc2"]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct", "domain_resolver": "local"}],
  "route": {"default_domain_resolver": "local", "final": "direct"}
}
EOF

if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]]; then
    "$SB" check -c "$TMP/config.json" && ok "sing-box config validation" || fail "sing-box config validation"
else
    ok "sing-box config validation (skipped: no snakeoil cert)"
fi

rm -rf "$TMP"
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
