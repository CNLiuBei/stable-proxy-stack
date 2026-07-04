#!/usr/bin/env bash
# TLS 自动续签 — 由 cron 每日调用，仅在证书临近到期时续签
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"

log() {
    echo "$(date '+%F %T') [renew] $*"
}

[[ -f "${INSTALL_DIR}/cert.env" ]] || exit 0
# shellcheck source=/dev/null
source "${INSTALL_DIR}/cert.env"

[[ -n "${DOMAIN:-}" ]] || exit 0

ACME="${HOME}/.acme.sh/acme.sh"
if [[ ! -x "${ACME}" ]]; then
    log "acme.sh 未安装，跳过"
    exit 0
fi

# shellcheck source=/dev/null
source "${HOME}/.acme.sh/acme.sh.env" 2>/dev/null || true

if [[ "${CERT_MODE:-}" == "cf" && -f "${INSTALL_DIR}/cf-token" ]]; then
    CF_Token=$(<"${INSTALL_DIR}/cf-token")
    export CF_Token
fi

nginx_stopped=false
if [[ "${CERT_MODE:-}" == "standalone" ]]; then
    if systemctl stop nginx 2>/dev/null; then
        nginx_stopped=true
    fi
fi

cleanup() {
    if [[ "${nginx_stopped}" == true ]]; then
        systemctl start nginx 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "检查 ${DOMAIN} 证书是否需要续签..."

renew_out=""
renew_rc=0
renew_out=$("${ACME}" --renew -d "${DOMAIN}" --ecc --server letsencrypt 2>&1) || renew_rc=$?

if echo "${renew_out}" | grep -qiE 'Skip|not exceeded|not due|does not need|no need|already'; then
    log "证书有效，暂无需续签"
    exit 0
fi

if [[ ${renew_rc} -eq 0 ]]; then
    log "证书续签成功"
    if [[ -x "${INSTALL_DIR}/scripts/renew-hook.sh" ]]; then
        /bin/bash "${INSTALL_DIR}/scripts/renew-hook.sh"
    fi
    end=$(openssl x509 -in "${INSTALL_DIR}/tls/${DOMAIN}.crt" -noout -enddate 2>/dev/null | cut -d= -f2- || true)
    [[ -n "${end}" ]] && log "新证书到期: ${end}"
    exit 0
fi

log "续签未完成（退出码 ${renew_rc}）"
[[ -n "${renew_out}" ]] && log "${renew_out}"
exit 0
