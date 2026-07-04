#!/usr/bin/env bash
#
# stable-proxy-stack: VLESS Reality (stable) + Hysteria2 (speed backup)
#
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"
WEB_ROOT="/var/www/stable-proxy"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main}"
REALITY_DEST="${REALITY_DEST:-dl.google.com}"
HY2_PORT_END="${HY2_PORT_END:-450}"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.14}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DOMAIN=""
EMAIL=""
CF_TOKEN=""
CHECK_ONLY=false
SKIP_CHECK=false
ASSUME_YES=false

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*" >&2; }
err()  { fail "$*"; exit 1; }

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNS=()

add_error() { PREFLIGHT_ERRORS+=("$1"); }
add_warn()  { PREFLIGHT_WARNS+=("$1"); }

usage() {
    cat <<EOF
Usage: bash install.sh --domain DOMAIN [options]

Options:
  --domain DOMAIN       Required. Your domain
  --email EMAIL         ACME email (default: admin@DOMAIN)
  --cf-token TOKEN      Cloudflare API token for DNS ACME (skip port 80 requirement)
  --reality-dest HOST   Reality dest/SNI (default: dl.google.com)
  --hy2-port-end PORT   UDP port hopping end (default: 450)
  --sing-box-version V  sing-box version (default: 1.13.14)
  --check-only          Run environment checks only, do not install
  --skip-check          Skip preflight checks (not recommended)
  -y, --yes             Continue when only warnings (no errors)
  -h, --help            Show help

Examples:
  bash install.sh --domain jp.example.com --email admin@example.com
  bash install.sh --domain jp.example.com --cf-token YOUR_CF_TOKEN
  bash install.sh --domain jp.example.com --check-only
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
        --check-only) CHECK_ONLY=true; shift ;;
        --skip-check) SKIP_CHECK=true; shift ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done

[[ -n "${DOMAIN}" ]] || { usage; err "--domain is required"; }

wait_dpkg_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [[ ${waited} -eq 0 ]]; then
            warn "Waiting for apt/dpkg lock (unattended-upgrades may be running)..."
        fi
        sleep 5
        waited=$((waited + 5))
        [[ ${waited} -lt 300 ]] || err "apt/dpkg lock timeout after 300s"
    done
}

# Download URL to stdout or file. Prefers curl, falls back to wget.
http_get() {
    local url="$1"
    local dest="${2:-}"
    local timeout="${3:-60}"

    if command -v curl >/dev/null 2>&1; then
        if [[ -n "${dest}" ]]; then
            curl -fsSL --max-time "${timeout}" "${url}" -o "${dest}"
        else
            curl -fsSL --max-time "${timeout}" "${url}"
        fi
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        if [[ -n "${dest}" ]]; then
            wget -q --timeout="${timeout}" -O "${dest}" "${url}"
        else
            wget -q --timeout="${timeout}" -O - "${url}"
        fi
        return 0
    fi
    err "curl or wget is required. On Debian/Ubuntu: apt-get update && apt-get install -y curl wget ca-certificates"
}

# HEAD/probe URL (for preflight reachability checks).
http_probe() {
    local url="$1"
    local timeout="${2:-10}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --max-time "${timeout}" "${url}" >/dev/null 2>&1
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --spider -q --timeout="${timeout}" "${url}" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Install curl/wget before preflight (minimal VPS images often lack curl).
ensure_bootstrap_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v wget >/dev/null 2>&1 || missing+=("wget")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        err "Missing ${missing[*]} and not root — cannot auto-install. Run as root or: apt-get install -y curl wget ca-certificates"
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        err "Missing ${missing[*]}. This script supports Debian/Ubuntu only; install curl/wget manually first."
    fi

    wait_dpkg_lock
    log "Installing bootstrap tools (${missing[*]})..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl wget >/dev/null 2>&1 \
        || apt-get install -y ca-certificates curl wget \
        || err "Failed to install curl/wget. Run: apt-get update && apt-get install -y curl wget ca-certificates"

    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || err "Neither curl nor wget available after bootstrap install"
    log "Bootstrap tools ready: $(command -v curl 2>/dev/null || echo no-curl) $(command -v wget 2>/dev/null || echo no-wget)"
}

get_public_ipv4() {
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsS --max-time 8 https://api4.ipify.org 2>/dev/null \
            || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
            || curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null \
            || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -4 --timeout=8 -O - https://api4.ipify.org 2>/dev/null \
            || wget -q -4 --timeout=8 -O - https://ifconfig.me 2>/dev/null \
            || true
    fi
}

get_public_ipv6() {
    if command -v curl >/dev/null 2>&1; then
        curl -6 -fsS --max-time 8 https://api6.ipify.org 2>/dev/null \
            || curl -6 -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
            || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -6 --timeout=8 -O - https://api6.ipify.org 2>/dev/null \
            || wget -q -6 --timeout=8 -O - https://ifconfig.me 2>/dev/null \
            || true
    fi
}

resolve_dns() {
    local qtype="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short "${DOMAIN}" "${qtype}" 2>/dev/null | grep -v '^$' | head -10
    elif command -v host >/dev/null 2>&1; then
        if [[ "${qtype}" == "A" ]]; then host -t A "${DOMAIN}" 2>/dev/null | awk '/has address/ {print $4}'; fi
        if [[ "${qtype}" == "AAAA" ]]; then host -t AAAA "${DOMAIN}" 2>/dev/null | awk '/has IPv6 address/ {print $5}'; fi
    else
        getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}

port_in_use() {
    local port="$1"
    local proto="$2"
    if [[ "${proto}" == "tcp" ]]; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
    else
        ss -ulnH "sport = :${port}" 2>/dev/null | grep -q .
    fi
}

check_connectivity() {
    local host="$1" port="$2" proto="${3:-tcp}" label="$4"
    if [[ "${proto}" == "tcp" ]]; then
        timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    else
        timeout 3 nc -u -z -w 2 "${host}" "${port}" 2>/dev/null && return 0
    fi
    return 1
}

run_preflight() {
    PREFLIGHT_ERRORS=()
    PREFLIGHT_WARNS=()

    echo
    echo "============================================================"
    echo "  stable-proxy-stack preflight check"
    echo "============================================================"
    info "Domain: ${DOMAIN}"
    info "Cert mode: $([[ -n "${CF_TOKEN}" ]] && echo 'Cloudflare DNS' || echo "Let's Encrypt Standalone (needs TCP 80)")"
    echo

    # root
    if [[ "${EUID}" -ne 0 ]]; then
        add_error "Must run as root"
    else
        info "User: root OK"
    fi

    # OS
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) info "OS: ${PRETTY_NAME:-unknown} OK" ;;
            *) add_warn "OS ${PRETTY_NAME:-unknown} not officially tested (Debian/Ubuntu recommended)" ;;
        esac
    else
        add_warn "Cannot detect OS version"
    fi

    # arch
    case "$(uname -m)" in
        x86_64|aarch64) info "Arch: $(uname -m) OK" ;;
        *) add_error "Unsupported architecture: $(uname -m) (need x86_64 or aarch64)" ;;
    esac

    # memory
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ ${mem_mb} -lt 512 ]]; then
        add_error "Memory too low: ${mem_mb}MB (need >= 512MB)"
    elif [[ ${mem_mb} -lt 1024 ]]; then
        add_warn "Memory ${mem_mb}MB is low, recommend >= 1GB for dual-protocol"
    else
        info "Memory: ${mem_mb}MB OK"
    fi

    # disk
    local disk_free_mb
    disk_free_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [[ ${disk_free_mb} -lt 1024 ]]; then
        add_warn "Disk free space low: ${disk_free_mb}MB"
    else
        info "Disk free: ${disk_free_mb}MB OK"
    fi

    # dpkg lock
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        add_warn "apt/dpkg is locked (will wait during install)"
    else
        info "apt/dpkg lock: free OK"
    fi

    # network / public IP
    PUBLIC_IPV4=$(get_public_ipv4)
    PUBLIC_IPV6=$(get_public_ipv6)
    if [[ -n "${PUBLIC_IPV4}" ]]; then
        info "Server IPv4: ${PUBLIC_IPV4}"
    else
        add_warn "Cannot detect public IPv4 (DNS A record check may be skipped)"
    fi
    if [[ -n "${PUBLIC_IPV6}" ]]; then
        info "Server IPv6: ${PUBLIC_IPV6}"
    fi

    # DNS A record
    mapfile -t DNS_A < <(resolve_dns A || true)
    if [[ ${#DNS_A[@]} -eq 0 ]]; then
        add_error "DNS A record not found for ${DOMAIN} (add A record first)"
    else
        info "DNS A: ${DNS_A[*]}"
        if [[ -n "${PUBLIC_IPV4}" ]]; then
            local matched=false
            for ip in "${DNS_A[@]}"; do
                [[ "${ip}" == "${PUBLIC_IPV4}" ]] && matched=true
            done
            if [[ "${matched}" == false ]]; then
                add_error "DNS A (${DNS_A[*]}) does not match server IPv4 (${PUBLIC_IPV4})"
                add_warn "If using Cloudflare orange cloud, switch to DNS only (grey cloud)"
            else
                info "DNS A matches server IPv4 OK"
            fi
        fi
    fi

    # DNS AAAA (optional)
    mapfile -t DNS_AAAA < <(resolve_dns AAAA || true)
    if [[ ${#DNS_AAAA[@]} -gt 0 ]]; then
        info "DNS AAAA: ${DNS_AAAA[*]}"
        if [[ -n "${PUBLIC_IPV6}" ]]; then
            local matched6=false
            for ip in "${DNS_AAAA[@]}"; do
                [[ "${ip}" == "${PUBLIC_IPV6}" ]] && matched6=true
            done
            [[ "${matched6}" == true ]] && info "DNS AAAA matches server IPv6 OK" \
                || add_warn "DNS AAAA does not match server IPv6 (IPv6 optional)"
        fi
    fi

    # local port conflicts
    for spec in "443/tcp" "80/tcp"; do
        local p="${spec%/*}" proto="${spec#*/}"
        if port_in_use "${p}" "${proto}"; then
            add_warn "Port ${p}/${proto} already in use (will be reconfigured)"
        else
            info "Port ${p}/${proto} free OK"
        fi
    done

    # firewall / cloud firewall hints for standalone
    if [[ -z "${CF_TOKEN}" ]]; then
        add_warn "Standalone cert needs TCP 80 reachable from internet"
        add_warn "Open cloud firewall (Vultr/AWS/etc): 22,80,443/tcp,443/udp,8443,444-${HY2_PORT_END}/udp"
        if [[ -n "${PUBLIC_IPV4}" ]]; then
            if ! check_connectivity "${PUBLIC_IPV4}" 80 tcp; then
                add_warn "Cannot connect to self:${PUBLIC_IPV4}:80 (cloud firewall may block 80)"
                add_warn "Use --cf-token for DNS cert if port 80 is blocked"
            fi
        fi
    else
        info "Cloudflare DNS cert: port 80 not required OK"
    fi

    # required ports list
    info "Required ports: 22/tcp 80/tcp 443/tcp 443/udp 8443/tcp 444-${HY2_PORT_END}/udp"

    # download tools
    if command -v curl >/dev/null 2>&1; then
        info "Download tool: curl OK"
    elif command -v wget >/dev/null 2>&1; then
        info "Download tool: wget OK (curl not installed)"
    else
        add_error "Neither curl nor wget found (bootstrap should have installed them)"
    fi

    # sing-box version reachable
    local sb_arch
    case "$(uname -m)" in
        x86_64) sb_arch="amd64" ;;
        aarch64) sb_arch="arm64" ;;
        *) sb_arch="" ;;
    esac
    local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${sb_arch}.tar.gz"
    if [[ -n "${sb_arch}" ]] && ! http_probe "${sb_url}" 10; then
        add_error "Cannot download sing-box v${SING_BOX_VERSION} (${sb_arch}; check version or network)"
    else
        info "sing-box v${SING_BOX_VERSION} downloadable OK"
    fi

    # summary
    echo
    echo "------------------------------------------------------------"
    if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
        fail "Preflight failed with ${#PREFLIGHT_ERRORS[@]} error(s):"
        for e in "${PREFLIGHT_ERRORS[@]}"; do fail "  - ${e}"; done
        if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
            warn "Warnings:"
            for w in "${PREFLIGHT_WARNS[@]}"; do warn "  - ${w}"; done
        fi
        echo "============================================================"
        return 1
    fi

    if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
        warn "Preflight passed with ${#PREFLIGHT_WARNS[@]} warning(s):"
        for w in "${PREFLIGHT_WARNS[@]}"; do warn "  - ${w}"; done
        if [[ "${ASSUME_YES}" == false && "${CHECK_ONLY}" == false ]]; then
            echo
            read -r -p "Continue install? [y/N]: " ans
            [[ "${ans}" =~ ^[Yy]$ ]] || err "Install cancelled"
        fi
    else
        log "Preflight: all checks passed"
    fi
    echo "============================================================"
    echo
    return 0
}

fetch_asset() {
    local rel_path="$1"
    local dest_path="$2"
    local script_src
    script_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_src="."

    if [[ -f "${script_src}/${rel_path}" ]]; then
        install -m 755 "${script_src}/${rel_path}" "${dest_path}" 2>/dev/null || cp "${script_src}/${rel_path}" "${dest_path}"
    else
        http_get "${REPO_BASE}/${rel_path}" "${dest_path}"
        chmod 755 "${dest_path}" 2>/dev/null || true
    fi
}

install_packages() {
    wait_dpkg_lock
    log "Installing packages..."
    apt-get update -qq
    apt-get install -y -qq curl wget jq openssl ca-certificates ufw nginx iptables dnsutils netcat-openbsd \
        >/dev/null 2>&1 \
        || apt-get install -y curl wget jq openssl ca-certificates ufw nginx iptables dnsutils netcat-openbsd
}

apply_sysctl() {
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
}

install_singbox_binary() {
    log "Installing sing-box ${SING_BOX_VERSION}..."
    mkdir -p "${INSTALL_DIR}/sing-box"
    local arch sb_arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) sb_arch="amd64" ;;
        aarch64) sb_arch="arm64" ;;
        *) err "Unsupported arch: ${arch}" ;;
    esac
    local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${sb_arch}.tar.gz"
    http_get "${sb_url}" | tar -xzf - -C /tmp
    install -m 755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${sb_arch}/sing-box" "${INSTALL_DIR}/sing-box/sing-box"
    ln -sf "${INSTALL_DIR}/sing-box/sing-box" /usr/local/bin/sing-box
}

issue_tls_cert() {
    log "Issuing TLS certificate..."
    local tls_dir="${INSTALL_DIR}/tls"
    mkdir -p "${tls_dir}"

    if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
        http_get "https://get.acme.sh" | sh -s email="${EMAIL}" >/dev/null 2>&1
    fi
    # shellcheck source=/dev/null
    source "${HOME}/.acme.sh/acme.sh.env" 2>/dev/null || true
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if [[ -n "${CF_TOKEN}" ]]; then
        export CF_Token="${CF_TOKEN}"
        "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --force --server letsencrypt
    else
        systemctl stop nginx 2>/dev/null || true
        "${HOME}/.acme.sh/acme.sh" --issue --standalone -d "${DOMAIN}" --keylength ec-256 --force --server letsencrypt
    fi

    "${HOME}/.acme.sh/acme.sh" --install-cert -d "${DOMAIN}" --ecc \
        --key-file "${tls_dir}/${DOMAIN}.key" \
        --fullchain-file "${tls_dir}/${DOMAIN}.crt" \
        --reloadcmd "systemctl reload nginx 2>/dev/null; systemctl restart sing-box 2>/dev/null"
}

write_singbox_config() {
    log "Writing sing-box config..."
    local tls_dir="${INSTALL_DIR}/tls"
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
        "certificate_path": "${tls_dir}/${DOMAIN}.crt",
        "key_path": "${tls_dir}/${DOMAIN}.key"
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
}

setup_nginx() {
    log "Configuring nginx decoy site..."
    local tls_dir="${INSTALL_DIR}/tls"
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
    ssl_certificate     ${tls_dir}/${DOMAIN}.crt;
    ssl_certificate_key ${tls_dir}/${DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${WEB_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
    nginx -t
}

setup_systemd() {
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
    systemctl restart sing-box
}

setup_firewall() {
    log "Configuring firewall..."
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow 8443/tcp
    local p
    for p in $(seq 444 "${HY2_PORT_END}"); do ufw allow "${p}/udp" 2>/dev/null; done
    ufw --force enable
}

setup_cron() {
    log "Setting up cron jobs..."
    (crontab -l 2>/dev/null | grep -v stable-proxy; \
     echo "*/5 * * * * /bin/bash ${INSTALL_DIR}/scripts/healthcheck.sh"; \
     echo "0 3 * * * ${HOME}/.acme.sh/acme.sh --renew -d ${DOMAIN} --force && /bin/bash ${INSTALL_DIR}/scripts/renew-hook.sh") \
    | crontab -
}

verify_install() {
    local ok=true
    echo
    log "Verifying installation..."
    for svc in sing-box nginx stable-proxy-port-hopping; do
        if systemctl is-active --quiet "${svc}"; then
            info "Service ${svc}: running"
        else
            fail "Service ${svc}: NOT running"
            ok=false
        fi
    done
    if ss -tlnH 'sport = :443' 2>/dev/null | grep -q sing-box; then
        info "TCP 443 (Reality): listening"
    else
        fail "TCP 443 (Reality): not listening"
        ok=false
    fi
    if ss -ulnH 'sport = :443' 2>/dev/null | grep -q sing-box; then
        info "UDP 443 (hy2): listening"
    else
        fail "UDP 443 (hy2): not listening"
        ok=false
    fi
    if [[ -f "${INSTALL_DIR}/tls/${DOMAIN}.crt" ]]; then
        info "TLS cert: OK ($(openssl x509 -in "${INSTALL_DIR}/tls/${DOMAIN}.crt" -noout -enddate 2>/dev/null | cut -d= -f2))"
    else
        fail "TLS cert: missing"
        ok=false
    fi
    [[ "${ok}" == true ]] || err "Post-install verification failed"
}

print_links() {
    REALITY_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUB}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#reality-main"
    HY2_LINK="hysteria2://${UUID}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&mport=443-${HY2_PORT_END}&peer=${DOMAIN}&insecure=0&sni=${DOMAIN}&alpn=h3#hy2-backup"

    cat >"${INSTALL_DIR}/subscribe.txt" <<EOF
# stable-proxy-stack
# Domain: ${DOMAIN}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# [主力·稳定] VLESS + Reality + Vision
${REALITY_LINK}

# [备用·速度] Hysteria2 + obfs + 端口跳跃
${HY2_LINK}
EOF
    chmod 600 "${INSTALL_DIR}/subscribe.txt"

    cat >"${INSTALL_DIR}/credentials.txt" <<EOF
DOMAIN=${DOMAIN}
UUID=${UUID}
OBFS_PASSWORD=${OBFS_PASS}
REALITY_PUBLIC_KEY=${REALITY_PUB}
REALITY_DEST=${REALITY_DEST}
REALITY_SHORT_ID=6ba85179e30d4fc2
SERVER_IPV4=${PUBLIC_IPV4:-unknown}
EOF
    chmod 600 "${INSTALL_DIR}/credentials.txt"

    cat >"${INSTALL_DIR}/clash-meta.yaml" <<EOF
proxies:
  - name: "reality-main"
    type: vless
    server: ${DOMAIN}
    port: 443
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    reality-opts:
      public-key: ${REALITY_PUB}
      short-id: 6ba85179e30d4fc2
    client-fingerprint: chrome
  - name: "hy2-backup"
    type: hysteria2
    server: ${DOMAIN}
    port: 443
    ports: 443-${HY2_PORT_END}
    password: ${UUID}
    obfs: salamander
    obfs-password: ${OBFS_PASS}
    sni: ${DOMAIN}
    alpn: [h3]

proxy-groups:
  - name: "稳定优先"
    type: fallback
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies: [reality-main, hy2-backup]
EOF
    chmod 600 "${INSTALL_DIR}/clash-meta.yaml"

    echo
    echo "============================================================"
    echo -e "${GREEN}  Installation complete!${NC}"
    echo "============================================================"
    echo
    echo "  Domain:     ${DOMAIN}"
    echo "  Server IP:  ${PUBLIC_IPV4:-unknown}"
    echo "  Saved:      ${INSTALL_DIR}/subscribe.txt"
    echo "              ${INSTALL_DIR}/credentials.txt"
    echo "              ${INSTALL_DIR}/clash-meta.yaml"
    echo
    echo -e "${YELLOW}[主力·稳定] VLESS + Reality + Vision${NC}"
    echo "${REALITY_LINK}"
    echo
    echo -e "${YELLOW}[备用·速度] Hysteria2 + obfs${NC}"
    echo "${HY2_LINK}"
    echo
    echo "Client tips:"
    echo "  - Clash Meta: import ${INSTALL_DIR}/clash-meta.yaml"
    echo "  - Use fallback: reality-main -> hy2-backup"
    echo "  - Test: visit https://www.google.com"
    echo
    echo "Cloud firewall reminder:"
    echo "  Open: 22, 80, 443/tcp, 443/udp, 8443, 444-${HY2_PORT_END}/udp"
    echo "============================================================"
}

# ── Main ────────────────────────────────────────────────────────────
EMAIL="${EMAIL:-admin@${DOMAIN}}"
export DEBIAN_FRONTEND=noninteractive

# curl/wget required for preflight and downloads; auto-install on minimal images
ensure_bootstrap_tools

if [[ "${SKIP_CHECK}" == false ]]; then
    run_preflight || exit 1
fi

if [[ "${CHECK_ONLY}" == true ]]; then
    log "Check-only mode complete."
    exit 0
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
OBFS_PASS=$(openssl rand -hex 8)
log "UUID: ${UUID}"

install_packages
apply_sysctl
install_singbox_binary

REALITY_KEYS=$("${INSTALL_DIR}/sing-box/sing-box" generate reality-keypair)
REALITY_PRIV=$(echo "${REALITY_KEYS}" | awk '/PrivateKey/ {print $2}')
REALITY_PUB=$(echo "${REALITY_KEYS}" | awk '/PublicKey/ {print $2}')
[[ -n "${REALITY_PRIV}" && -n "${REALITY_PUB}" ]] || err "Failed to generate Reality keys"

issue_tls_cert

mkdir -p "${INSTALL_DIR}/scripts" "${WEB_ROOT}"
fetch_asset "scripts/port-hopping.sh" "${INSTALL_DIR}/scripts/port-hopping.sh"
fetch_asset "scripts/healthcheck.sh" "${INSTALL_DIR}/scripts/healthcheck.sh"
fetch_asset "scripts/renew-hook.sh" "${INSTALL_DIR}/scripts/renew-hook.sh"
fetch_asset "assets/index.html" "${WEB_ROOT}/index.html"

write_singbox_config
setup_nginx
setup_systemd
setup_firewall
setup_cron
verify_install
print_links
