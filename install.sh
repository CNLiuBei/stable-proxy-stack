#!/usr/bin/env bash
#
# stable-proxy-stack: VLESS Reality (stable) + Hysteria2 (speed backup)
# One-click installer for Debian/Ubuntu VPS
#
# Usage:
#   bash install.sh --domain example.com --email admin@example.com
#   bash install.sh --domain example.com --cf-token YOUR_CF_TOKEN
#
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"
WEB_ROOT="/var/www/stable-proxy"
REALITY_DEST="${REALITY_DEST:-dl.google.com}"
HY2_PORT_END="${HY2_PORT_END:-450}"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.14}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

DOMAIN=""
EMAIL=""
CF_TOKEN=""

usage() {
    cat <<EOF
Usage: bash install.sh --domain DOMAIN [options]

Options:
  --domain DOMAIN       Required. Your domain (must point to this VPS)
  --email EMAIL         ACME email (default: admin@DOMAIN)
  --cf-token TOKEN      Cloudflare API token for DNS ACME (optional)
  --reality-dest HOST   Reality dest/SNI (default: dl.google.com)
  --hy2-port-end PORT   UDP port hopping end (default: 450)
  --sing-box-version V  sing-box version (default: 1.13.14)
  -h, --help            Show help

One-line install example:
  curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- --domain example.com --email admin@example.com
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --reality-dest) REALITY_DEST="$2"; shift 2 ;;
        --hy2-port-end) HY2_PORT_END="$2"; shift 2 ;;
        --sing-box-version) SING_BOX_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done

[[ -n "${DOMAIN}" ]] || { usage; err "--domain is required"; }
[[ "${EUID}" -eq 0 ]] || err "Please run as root"

EMAIL="${EMAIL:-admin@${DOMAIN}}"

export DEBIAN_FRONTEND=noninteractive

log "Domain: ${DOMAIN}"
log "Reality dest: ${REALITY_DEST}"
log "Install dir: ${INSTALL_DIR}"

UUID=$(cat /proc/sys/kernel/random/uuid)
OBFS_PASS=$(openssl rand -hex 8)
log "UUID: ${UUID}"

# ── Install dependencies ────────────────────────────────────────────
log "Installing packages..."
apt-get update -qq
apt-get install -y -qq curl wget jq openssl ca-certificates gnupg ufw nginx iptables \
    >/dev/null 2>&1 || apt-get install -y curl wget jq openssl ca-certificates ufw nginx iptables

# ── System tuning ───────────────────────────────────────────────────
log "Applying sysctl tuning..."
cat >/etc/sysctl.d/99-stable-proxy.conf <<'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.core.netdev_max_backlog = 250000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10
fs.file-max = 65536
EOF
sysctl -p /etc/sysctl.d/99-stable-proxy.conf >/dev/null 2>&1 || true

# ── Install sing-box ────────────────────────────────────────────────
log "Installing sing-box ${SING_BOX_VERSION}..."
mkdir -p "${INSTALL_DIR}/sing-box"
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    *) err "Unsupported arch: ${ARCH}" ;;
esac
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}.tar.gz"
curl -fsSL "${SB_URL}" | tar -xzf - -C /tmp
install -m 755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}/sing-box" "${INSTALL_DIR}/sing-box/sing-box"
ln -sf "${INSTALL_DIR}/sing-box/sing-box" /usr/local/bin/sing-box

REALITY_KEYS=$("${INSTALL_DIR}/sing-box/sing-box" generate reality-keypair)
REALITY_PRIV=$(echo "${REALITY_KEYS}" | awk '/PrivateKey/ {print $2}')
REALITY_PUB=$(echo "${REALITY_KEYS}" | awk '/PublicKey/ {print $2}')
[[ -n "${REALITY_PRIV}" && -n "${REALITY_PUB}" ]] || err "Failed to generate Reality keys"

# ── TLS certificate (acme.sh) ───────────────────────────────────────
log "Issuing TLS certificate..."
TLS_DIR="${INSTALL_DIR}/tls"
mkdir -p "${TLS_DIR}"

if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}" >/dev/null 2>&1
fi
# shellcheck source=/dev/null
source "${HOME}/.acme.sh/acme.sh.env" 2>/dev/null || true
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

if [[ -n "${CF_TOKEN}" ]]; then
    export CF_Token="${CF_TOKEN}"
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --force --server letsencrypt
else
    systemctl stop nginx 2>/dev/null || true
    ~/.acme.sh/acme.sh --issue --standalone -d "${DOMAIN}" --keylength ec-256 --force --server letsencrypt
fi

~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --ecc \
    --key-file "${TLS_DIR}/${DOMAIN}.key" \
    --fullchain-file "${TLS_DIR}/${DOMAIN}.crt" \
    --reloadcmd "systemctl reload nginx; systemctl restart sing-box"

# ── Directory layout ────────────────────────────────────────────────
mkdir -p "${INSTALL_DIR}/scripts" "${WEB_ROOT}"
SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in port-hopping.sh healthcheck.sh renew-hook.sh; do
    if [[ -f "${SCRIPT_SRC}/scripts/${f}" ]]; then
        install -m 755 "${SCRIPT_SRC}/scripts/${f}" "${INSTALL_DIR}/scripts/${f}"
    fi
done

if [[ -f "${SCRIPT_SRC}/assets/index.html" ]]; then
    cp "${SCRIPT_SRC}/assets/index.html" "${WEB_ROOT}/index.html"
else
    echo '<html><body><h1>Tech Blog</h1></body></html>' > "${WEB_ROOT}/index.html"
fi

# ── sing-box config ─────────────────────────────────────────────────
log "Writing sing-box config..."
cat >"${INSTALL_DIR}/config.json" <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "tag": "local", "type": "local" },
      { "tag": "google", "type": "tls", "server": "8.8.8.8", "detour": "direct" }
    ],
    "strategy": "prefer_ipv4",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 443,
      "ignore_client_bandwidth": true,
      "obfs": { "type": "salamander", "password": "${OBFS_PASS}" },
      "users": [{ "name": "hy2-backup", "password": "${UUID}" }],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "${TLS_DIR}/${DOMAIN}.crt",
        "key_path": "${TLS_DIR}/${DOMAIN}.key"
      },
      "masquerade": {
        "type": "proxy",
        "url": "https://news.ycombinator.com/",
        "rewrite_host": true
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "tag": "VLESSReality",
      "users": [{
        "name": "reality-main",
        "uuid": "${UUID}",
        "flow": "xtls-rprx-vision"
      }],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_DEST}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["", "6ba85179e30d4fc2"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct", "domain_resolver": "local" }],
  "route": {
    "default_domain_resolver": "local",
    "rules": [{ "action": "sniff", "timeout": "1s" }],
    "final": "direct"
  }
}
EOF

sing-box check -c "${INSTALL_DIR}/config.json" || err "sing-box config validation failed"

# Save credentials
cat >"${INSTALL_DIR}/credentials.txt" <<EOF
DOMAIN=${DOMAIN}
UUID=${UUID}
OBFS_PASSWORD=${OBFS_PASS}
REALITY_PUBLIC_KEY=${REALITY_PUB}
REALITY_DEST=${REALITY_DEST}
REALITY_SHORT_ID=6ba85179e30d4fc2
EOF
chmod 600 "${INSTALL_DIR}/credentials.txt"

# ── Nginx decoy site (8443) ─────────────────────────────────────────
log "Configuring nginx decoy site..."
cat >/etc/nginx/conf.d/stable-proxy.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root ${WEB_ROOT}; }
    location / { return 301 https://\$host:8443\$request_uri; }
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    http2 on;
    server_name ${DOMAIN};
    ssl_certificate     ${TLS_DIR}/${DOMAIN}.crt;
    ssl_certificate_key ${TLS_DIR}/${DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${WEB_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
nginx -t

# ── systemd services ────────────────────────────────────────────────
log "Creating systemd services..."
cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box (stable-proxy-stack)
After=network.target

[Service]
Type=simple
User=root
Nice=-5
LimitNOFILE=infinity
ExecStart=${INSTALL_DIR}/sing-box/sing-box run -c ${INSTALL_DIR}/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/stable-proxy-port-hopping.service <<EOF
[Unit]
Description=stable-proxy UDP port hopping
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/scripts/port-hopping.sh 443 443 ${HY2_PORT_END}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box stable-proxy-port-hopping nginx
systemctl restart nginx
"${INSTALL_DIR}/scripts/port-hopping.sh" 443 443 "${HY2_PORT_END}" || true
systemctl enable stable-proxy-port-hopping
systemctl restart sing-box

# ── Firewall ────────────────────────────────────────────────────────
log "Configuring firewall..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 8443/tcp
for p in $(seq 444 "${HY2_PORT_END}"); do ufw allow "${p}/udp" 2>/dev/null; done
ufw --force enable

# ── Cron jobs ───────────────────────────────────────────────────────
log "Setting up cron jobs..."
(crontab -l 2>/dev/null | grep -v stable-proxy; \
 echo "*/5 * * * * /bin/bash ${INSTALL_DIR}/scripts/healthcheck.sh"; \
 echo "0 3 * * * ${HOME}/.acme.sh/acme.sh --renew -d ${DOMAIN} --force && /bin/bash ${INSTALL_DIR}/scripts/renew-hook.sh") \
 | crontab -

# ── Subscription links ──────────────────────────────────────────────
REALITY_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUB}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#reality-main"
HY2_LINK="hysteria2://${UUID}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&mport=443-${HY2_PORT_END}&peer=${DOMAIN}&insecure=0&sni=${DOMAIN}&alpn=h3#hy2-backup"

cat >"${INSTALL_DIR}/subscribe.txt" <<EOF
# stable-proxy-stack subscription
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# [主力·稳定] VLESS + Reality + Vision
${REALITY_LINK}

# [备用·速度] Hysteria2 + obfs + 端口跳跃
${HY2_LINK}
EOF
chmod 600 "${INSTALL_DIR}/subscribe.txt"

echo
echo "============================================================"
echo -e "${GREEN}  Installation complete!${NC}"
echo "============================================================"
echo
echo "Credentials saved: ${INSTALL_DIR}/credentials.txt"
echo "Subscribe links:   ${INSTALL_DIR}/subscribe.txt"
echo
echo -e "${YELLOW}[主力·稳定] Reality:${NC}"
echo "${REALITY_LINK}"
echo
echo -e "${YELLOW}[备用·速度] hy2:${NC}"
echo "${HY2_LINK}"
echo
echo "Clash Meta: use fallback group — Reality first, hy2 backup"
echo "Test: import Reality link, visit https://www.google.com"
echo "============================================================"
