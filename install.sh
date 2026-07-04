#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# IFIM-Proxy: VLESS Reality (stable) + Hysteria2 (speed backup)
#
# @commit: 821913a272656d83f7d81c828a953e1a9e299eab
SCRIPT_VERSION="2026.07.04+821913a"

set -euo pipefail
ORIG_INSTALL_ARGS=("$@")

# 确保终端中文不乱码（Debian/Ubuntu 优先 C.UTF-8）
setup_utf8_locale() {
    local loc
    for loc in C.UTF-8 en_US.UTF-8 zh_CN.UTF-8; do
        if locale -a 2>/dev/null | grep -qx "${loc}"; then
            export LANG="${loc}"
            export LC_ALL="${loc}"
            export LANGUAGE="${loc}"
            return 0
        fi
    done
    # 极简镜像可能未生成 UTF-8 locale
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq locales >/dev/null 2>&1 || true
        if [[ -f /etc/locale.gen ]]; then
            sed -i 's/^# \(en_US.UTF-8\)/\1/; s/^# \(C.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
        fi
        locale-gen en_US.UTF-8 2>/dev/null || locale-gen C.UTF-8 2>/dev/null || true
        for loc in C.UTF-8 en_US.UTF-8; do
            if locale -a 2>/dev/null | grep -qx "${loc}"; then
                export LANG="${loc}"
                export LC_ALL="${loc}"
                export LANGUAGE="${loc}"
                return 0
            fi
        done
    fi
    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
}

setup_utf8_locale

INSTALL_DIR="/etc/stable-proxy-stack"
WEB_ROOT="/var/www/stable-proxy"
GITHUB_REPO="${GITHUB_REPO:-CNLiuBei/IFIM-Proxy}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/${GITHUB_REPO}/main}"
REALITY_DEST="${REALITY_DEST:-dl.google.com}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-6ba85179e30d4fc2}"
HY2_PORT_END="${HY2_PORT_END:-450}"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.14}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DOMAIN=""
EMAIL=""
CF_TOKEN=""
CERT_MODE=""   # cf | standalone
CHECK_ONLY=false
SKIP_CHECK=false
SKIP_VERSION_CHECK=false
ASSUME_YES=false
DNS_CONFIRMED=false
SUB_PANEL_TOKEN=""
PANEL_URL=""

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*" >&2; }
err()  { fail "$*"; exit 1; }

show_script_version() {
    echo -e "${CYAN}[i]${NC} IFIM-Proxy 安装脚本 ${BOLD}v${SCRIPT_VERSION}${NC}"
}

# 获取 GitHub main 最新 commit（绕过 raw CDN 缓存）
github_main_sha() {
    curl -fsSL --max-time 15 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/commits/main" \
        2>/dev/null | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1
}

fetch_remote_script_version() {
    local sha="$1"
    curl -fsSL --max-time 15 \
        "https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/install.sh" \
        2>/dev/null | grep -m1 '^SCRIPT_VERSION=' \
        | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p'
}

upgrade_install_script() {
    local sha="$1"
    local remote_ver="$2"
    local url tmp

    url="https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/install.sh"
    tmp=$(mktemp /tmp/ifim-install.XXXXXX.sh)
    if ! curl -fsSL --max-time 30 "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        err "无法下载最新脚本（v${remote_ver}），请稍后重试"
    fi
    chmod 755 "${tmp}"
    warn "当前 v${SCRIPT_VERSION} → 自动拉取最新 v${remote_ver}"
    SKIP_VERSION_CHECK=true
    export SKIP_VERSION_CHECK
    if [[ -r /dev/tty ]]; then
        exec bash "${tmp}" "${ORIG_INSTALL_ARGS[@]}" </dev/tty
    else
        exec bash "${tmp}" "${ORIG_INSTALL_ARGS[@]}"
    fi
}

# 读取 install.sh 内嵌的 commit ref（由 sync-version.sh / CI 写入）
get_script_commit_ref() {
    local src="${BASH_SOURCE[0]:-}"
    case "${src##*/}" in
        bash|sh|"") return 0 ;;
    esac
    [[ -f "${src}" ]] || return 0
    sed -n '1,20p' "${src}" | sed -n 's/^# @commit: //p' | head -1
}

# curl | bash 时 $0 为 bash，需落盘并从 /dev/tty 重跑才能交互
reexec_if_piped() {
    local src="${BASH_SOURCE[0]:-}"
    case "${src##*/}" in
        bash|sh) ;;
        *) return 0 ;;
    esac

    local sha tmp
    sha=$(github_main_sha) || err "无法连接 GitHub 获取安装脚本"
    tmp=$(mktemp /tmp/ifim-install.XXXXXX.sh)
    if ! curl -fsSL --max-time 30 \
        "https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/install.sh" \
        -o "${tmp}"; then
        rm -f "${tmp}"
        err "无法下载安装脚本"
    fi
    chmod 755 "${tmp}"
    export SKIP_VERSION_CHECK=true
    if [[ -r /dev/tty ]]; then
        exec bash "${tmp}" "${ORIG_INSTALL_ARGS[@]}" </dev/tty
    else
        exec bash "${tmp}" "${ORIG_INSTALL_ARGS[@]}"
    fi
}

fetch_remote_script_commit_ref() {
    local sha="$1"
    curl -fsSL --max-time 15 \
        "https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/install.sh" \
        2>/dev/null | sed -n '1,20p' | sed -n 's/^# @commit: //p' | head -1
}

# 与 GitHub 最新 commit 比对；发现旧版则自动下载并重跑
check_script_version() {
    local sha remote_ver local_ref remote_ref

    [[ "${SKIP_VERSION_CHECK}" == true ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0

    local_ref=$(get_script_commit_ref)
    sha=$(github_main_sha) || {
        warn "无法获取 GitHub 最新 commit，继续运行（当前 v${SCRIPT_VERSION}）"
        return 0
    }

    remote_ref=$(fetch_remote_script_commit_ref "${sha}") || true

    # curl | bash 时读不到本地 @commit，但版本号一致则视为最新
    if [[ -z "${local_ref}" && -n "${remote_ref}" ]]; then
        remote_ver=$(fetch_remote_script_version "${sha}") || true
        if [[ -n "${remote_ver}" && "${remote_ver}" == "${SCRIPT_VERSION}" ]]; then
            info "脚本已是最新（${remote_ref:0:7}）"
            return 0
        fi
    fi

    if [[ -n "${local_ref}" && -n "${remote_ref}" && "${local_ref}" == "${remote_ref}" ]]; then
        info "脚本已是最新（${remote_ref:0:7}）"
        return 0
    fi

    remote_ver=$(fetch_remote_script_version "${sha}") || true
    if [[ -z "${remote_ver}" ]]; then
        warn "无法读取远程脚本版本，继续运行（当前 v${SCRIPT_VERSION}）"
        return 0
    fi

    if [[ "${remote_ver}" == "${SCRIPT_VERSION}" && -n "${remote_ref}" && "${local_ref}" == "${remote_ref}" ]]; then
        info "脚本版本 v${SCRIPT_VERSION}（已是最新）"
        return 0
    fi

    upgrade_install_script "${sha}" "${remote_ver}"
}

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNS=()

add_error() { PREFLIGHT_ERRORS+=("$1"); }
add_warn()  { PREFLIGHT_WARNS+=("$1"); }

usage() {
    cat <<'EOF'
用法: bash install.sh [选项]

交互模式（默认）:
  不传 --domain 时将逐步询问域名、DNS、证书方式。

选项:
  --domain DOMAIN       域名（可选，省略则交互输入）
  --email EMAIL         ACME 邮箱（默认 admin@域名）
  --cf-token TOKEN      Cloudflare API Token（DNS 证书，跳过 CF 询问）
  --reality-dest HOST   Reality 伪装目标（默认 dl.google.com）
  --hy2-port-end PORT   hy2 UDP 端口跳跃上限（默认 450，须 >= 444）
  --sing-box-version V  sing-box 版本（默认 1.13.14）
  --reset-firewall      安装时重置 UFW 规则（默认仅增量添加）
  --check-only          仅环境预检，不安装
  --skip-check          跳过预检（不推荐）
  --skip-version-check  跳过与 GitHub 最新版本比对
  -y, --yes             非交互：自动确认 DNS/CF/警告
  -V, --version         显示脚本版本
  -h, --help            显示帮助

示例:
  bash install.sh
  bash install.sh --domain jp.example.com --email admin@example.com
  bash install.sh --domain jp.example.com --cf-token YOUR_CF_TOKEN -y
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
        --reset-firewall) RESET_FIREWALL=true; shift ;;
        --check-only) CHECK_ONLY=true; shift ;;
        --skip-check) SKIP_CHECK=true; shift ;;
        --skip-version-check) SKIP_VERSION_CHECK=true; shift ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        -V|--version) echo "IFIM-Proxy install.sh v${SCRIPT_VERSION}"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知选项: $1" ;;
    esac
done

if [[ "${HY2_PORT_END}" -lt 444 ]]; then
    err "--hy2-port-end 须 >= 444（当前: ${HY2_PORT_END}）"
fi

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local hint ans
    local tty="/dev/tty"

    if [[ "${default}" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    if [[ "${ASSUME_YES}" == true ]]; then
        [[ "${default}" == "y" ]]
        return
    fi

    if [[ -t 0 ]]; then
        read -r -p "${prompt} ${hint}: " ans
    elif [[ -r "${tty}" ]]; then
        read -r -p "${prompt} ${hint}: " ans <"${tty}"
    else
        err "${prompt}（非交互环境，请使用 -y 或通过命令行传参）"
    fi

    ans="${ans:-${default}}"
    [[ "${ans}" =~ ^[Yy]$ ]]
}

# Read a line from stdin or /dev/tty (works with curl | bash).
prompt_read() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local value=""
    local tty="/dev/tty"
    local line

    if [[ -n "${default}" ]]; then
        line="${prompt} [${default}]: "
    else
        line="${prompt}: "
    fi

    if [[ -t 0 ]]; then
        read -r -p "${line}" value
    elif [[ -r "${tty}" ]]; then
        read -r -p "${line}" value <"${tty}"
    else
        value="${default}"
    fi

    value="${value:-${default}}"
    printf -v "${var_name}" '%s' "${value}"
}

prompt_secret() {
    local prompt="$1"
    local var_name="$2"
    local visible="${3:-false}"
    local value=""
    local tty="/dev/tty"

    if [[ "${visible}" == true ]]; then
        info "Token 会显示在屏幕上，粘贴后按 Enter 确认"
        if [[ -t 0 || -r "${tty}" ]]; then
            stty echo 2>/dev/null || true
        fi
        if [[ -t 0 ]]; then
            read -r -p "${prompt}: " value
        elif [[ -r "${tty}" ]]; then
            read -r -p "${prompt}: " value <"${tty}" >"${tty}"
        else
            err "${prompt}（非交互环境，请使用 --cf-token 传参）"
        fi
    else
        info "输入时不显示字符（安全模式），粘贴后按 Enter；完成后会提示字符数"
        if [[ -t 0 ]]; then
            read -rs -p "${prompt}: " value
            echo
        elif [[ -r "${tty}" ]]; then
            read -rs -p "${prompt}: " value <"${tty}"
            echo
        else
            err "${prompt}（非交互环境，请使用 --cf-token 传参）"
        fi
        [[ -n "${value}" ]] && info "已接收 ${#value} 个字符"
    fi
    printf -v "${var_name}" '%s' "${value}"
}

ensure_dns_lookup() {
    command -v dig >/dev/null 2>&1 && return 0
    command -v host >/dev/null 2>&1 && return 0
    if [[ "${EUID}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        wait_dpkg_lock
        apt-get install -y -qq dnsutils >/dev/null 2>&1 \
            || apt-get install -y dnsutils >/dev/null 2>&1 \
            || true
    fi
}

normalize_domain() {
    local d="$1"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    d="${d%%:*}"
    echo "${d}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

validate_domain() {
    local d="$1"
    [[ -n "${d}" ]] || return 1
    [[ "${d}" == *.* ]] || return 1
    [[ "${d}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

validate_email() {
    local e="$1"
    [[ "${e}" == *@*.* ]]
}

get_apex_domain() {
    local d="$1"
    local parts n
    IFS='.' read -ra parts <<< "${d}"
    n=${#parts[@]}
    if [[ ${n} -ge 2 ]]; then
        echo "${parts[$((n - 2))]}.${parts[$((n - 1))]}"
    else
        echo "${d}"
    fi
}

# 常见 Cloudflare 代理 IP 段（橙色云）
is_cloudflare_proxy_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^104\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "${ip}" =~ ^172\.(6[4-9]|7[01])\. ]] && return 0
    [[ "${ip}" =~ ^173\.245\. ]] && return 0
    [[ "${ip}" =~ ^188\.114\. ]] && return 0
    [[ "${ip}" =~ ^190\.93\. ]] && return 0
    return 1
}

check_dns_anomalies() {
    local ip cf_proxy=false
    mapfile -t _dns_check < <(resolve_dns A || true)
    for ip in "${_dns_check[@]}"; do
        if is_cloudflare_proxy_ip "${ip}"; then
            cf_proxy=true
            warn "DNS 指向 Cloudflare 代理 IP（${ip}），域名开启了橙色云"
        fi
    done
    if [[ "${cf_proxy}" == true ]]; then
        err "请先在 Cloudflare 关闭橙色云，改为灰色云朵（仅 DNS）后重试"
    fi
}

check_existing_install() {
    [[ "${CHECK_ONLY}" == true ]] && return 0
    if [[ -f "${INSTALL_DIR}/config.json" ]] || [[ -f /etc/systemd/system/sing-box.service ]]; then
        warn "检测到本机已有 IFIM-Proxy 安装（${INSTALL_DIR}）"
        if [[ "${ASSUME_YES}" == false ]]; then
            prompt_yes_no "继续安装将覆盖现有配置，是否继续？" "n" \
                || err "已取消。如需完全卸载: bash uninstall.sh"
        else
            warn "非交互模式（-y）将覆盖现有配置"
        fi
    fi
}

show_public_ip() {
    if [[ -n "${PUBLIC_IPV4:-}" ]]; then
        info "本机公网 IPv4: ${PUBLIC_IPV4}"
    else
        warn "无法获取本机公网 IPv4"
    fi
}

validate_cf_token() {
    [[ -z "${CF_TOKEN}" ]] && return 0
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        warn "无法在线验证 CF Token（缺少 curl/wget）"
        return 0
    fi

    info "正在验证 Cloudflare Token..."
    local resp apex zone_name curl_rc=0

    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -sS --max-time 20 \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || curl_rc=$?
    else
        resp=$(wget -q --timeout=20 -O - \
            --header="Authorization: Bearer ${CF_TOKEN}" \
            "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || curl_rc=$?
    fi

    if [[ ${curl_rc} -ne 0 || -z "${resp}" ]]; then
        warn "无法连接 Cloudflare API（网络/DNS/超时），跳过 Token 在线验证"
        warn "证书申请阶段仍需要能访问 api.cloudflare.com；若失败请检查 VPS 出站 443 或改用 Standalone 模式"
        return 0
    fi
    if echo "${resp}" | grep -q '"success"[[:space:]]*:[[:space:]]*false'; then
        local cf_err
        cf_err=$(echo "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        if [[ -n "${cf_err}" ]]; then
            err "Cloudflare Token 无效: ${cf_err}（需 Zone → DNS → Edit 权限）"
        fi
        err "Cloudflare Token 无效或权限不足，请重新创建（需 DNS Edit 权限）"
    fi
    if ! echo "${resp}" | grep -q '"status"[[:space:]]*:[[:space:]]*"active"'; then
        err "Cloudflare Token 无效或已过期，请重新创建（需 DNS Edit 权限）"
    fi
    log "Cloudflare Token 有效"

    apex=$(get_apex_domain "${DOMAIN}")
    zone_name="${apex}"
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -fsS --max-time 20 \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones?name=${zone_name}" 2>/dev/null) || resp=""
    else
        resp=$(wget -q --timeout=20 -O - \
            --header="Authorization: Bearer ${CF_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones?name=${zone_name}" 2>/dev/null) || resp=""
    fi

    if [[ -n "${resp}" ]] && echo "${resp}" | grep -q '"success"[[:space:]]*:[[:space:]]*true' \
        && echo "${resp}" | grep -q '"id"'; then
        log "Cloudflare 账号中已找到域名 Zone: ${zone_name}"
    else
        warn "未在 Cloudflare 找到 Zone「${zone_name}」，请确认域名已添加到 CF"
        if [[ "${ASSUME_YES}" == false ]]; then
            prompt_yes_no "仍要继续？（Token 可能无法申请证书）" "n" \
                || err "请先将域名添加到 Cloudflare 后重试"
        fi
    fi
}

guard_standalone_port80() {
    [[ -n "${CF_TOKEN}" ]] && return 0
    info "证书方式: Let's Encrypt Standalone（需公网 80 端口）"
    info "本机 UFW 将在安装时自动检测并放行"
}

on_install_error() {
    local code=$?
    [[ ${code} -eq 0 ]] && return 0
    echo
    fail "安装过程中出错（退出码 ${code}）"
    warn "常见原因:"
    warn "  · DNS 未生效或 A 记录未指向本机"
    warn "  · Cloudflare 仍开启橙色云（应改灰色云朵）"
    warn "  · Standalone 模式但 TCP 80 不可达（检查 Nginx/占用或上游拦截）"
    warn "  · CF Token 权限不足（需 DNS Edit）"
    warn "修复后重新运行: bash install.sh"
    warn "如需回滚: bash uninstall.sh"
    exit "${code}"
}

show_welcome() {
    echo
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}  IFIM-Proxy — 交互式安装向导${NC}"
    echo -e "${BOLD}  版本 v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo
    echo "  将部署: VLESS Reality（稳定主力）+ Hysteria2（速度备用）"
    echo
    if [[ "${CHECK_ONLY}" == true ]]; then
        echo -e "  ${CYAN}模式:${NC} 仅环境预检（不安装）"
    else
        echo -e "  ${CYAN}模式:${NC} 完整安装"
    fi
    echo
    echo "  接下来将:"
    echo "    1. 输入域名（含格式校验）"
    echo "    2. 自动检测 DNS A 记录是否指向本机"
    echo "    3. 选择证书申请方式"
    echo "    4. 输入 ACME 邮箱"
    echo
    echo "  防呆机制: 橙色云检测 / 80 端口拦截 / 覆盖安装确认"
    echo
    echo -e "${BOLD}============================================================${NC}"
    echo
}

check_root_early() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 运行。尝试: sudo bash install.sh"
    fi
}

dns_matches_server() {
    local ip matched=false
    mapfile -t _dns_a < <(resolve_dns A || true)
    [[ ${#_dns_a[@]} -gt 0 && -n "${PUBLIC_IPV4:-}" ]] || return 1
    for ip in "${_dns_a[@]}"; do
        [[ "${ip}" == "${PUBLIC_IPV4}" ]] && matched=true
    done
    [[ "${matched}" == true ]]
}

show_dns_status() {
    mapfile -t DNS_A < <(resolve_dns A || true)
    echo
    info "本机 IPv4: ${PUBLIC_IPV4:-未知}"
    if [[ ${#DNS_A[@]} -gt 0 ]]; then
        info "域名 ${DOMAIN} 的 DNS A 记录: ${DNS_A[*]}"
        if dns_matches_server; then
            log "DNS A 记录与本机 IP 一致"
            return 0
        fi
        warn "DNS A 记录与本机 IP 不一致（本机: ${PUBLIC_IPV4:-未知}）"
        warn "若使用 Cloudflare，请设为灰色云朵（仅 DNS），勿开橙色代理"
        return 1
    fi
    warn "尚未查询到 ${DOMAIN} 的 DNS A 记录"
    return 1
}

prompt_domain() {
    local input normalized

    while true; do
        if [[ -z "${DOMAIN}" ]]; then
            prompt_read "请输入域名（例: jp.example.com）" input
            normalized=$(normalize_domain "${input}")
        else
            normalized=$(normalize_domain "${DOMAIN}")
            info "命令行指定域名: ${normalized}"
            if [[ "${ASSUME_YES}" == false ]]; then
                if ! prompt_yes_no "使用此域名？" "y"; then
                    DOMAIN=""
                    continue
                fi
            fi
        fi

        if validate_domain "${normalized}"; then
            DOMAIN="${normalized}"
            # 防呆: 常见拼写错误提示
            if [[ "${DOMAIN}" == *".con" ]] || [[ "${DOMAIN}" == *".cmo" ]] || [[ "${DOMAIN}" == *".ocm" ]]; then
                warn "域名后缀疑似拼写错误（${DOMAIN}），常见应为 .com"
                if [[ "${ASSUME_YES}" == false ]] && ! prompt_yes_no "确认域名无误？" "n"; then
                    DOMAIN=""
                    continue
                fi
            fi
            break
        fi
        warn "域名格式无效: ${input:-${DOMAIN}}（示例: jp.example.com）"
        DOMAIN=""
    done
}

auto_check_dns() {
    local attempt max_attempts=3 wait_sec=15

    echo
    echo -e "${BOLD}--- 步骤 2: DNS 自动检测 ---${NC}"

    if [[ -z "${PUBLIC_IPV4:-}" ]]; then
        DNS_CONFIRMED=false
        err "无法获取本机公网 IP，不能自动校验 DNS"
    fi

    echo "  需要: ${DOMAIN}  A  →  ${PUBLIC_IPV4}"
    echo

    for attempt in $(seq 1 "${max_attempts}"); do
        show_dns_status || true
        if dns_matches_server; then
            DNS_CONFIRMED=true
            log "DNS 自动检测通过"
            return 0
        fi
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "DNS 未指向本机，${wait_sec} 秒后重试 (${attempt}/${max_attempts})..."
            sleep "${wait_sec}"
        fi
    done

    DNS_CONFIRMED=false
    mapfile -t _fail_dns < <(resolve_dns A || true)
    if [[ ${#_fail_dns[@]} -eq 0 ]]; then
        err "DNS 检测失败: 未找到 ${DOMAIN} 的 A 记录。请添加 ${DOMAIN} A → ${PUBLIC_IPV4} 后重试"
    fi
    err "DNS 检测失败: 当前 A 记录 (${_fail_dns[*]}) ≠ 本机 IP (${PUBLIC_IPV4})"
}

prompt_cert_method() {
    local choice

    echo
    echo -e "${BOLD}--- 步骤 3: 证书申请 ---${NC}"
    echo "  [1] Cloudflare DNS  — 推荐，无需开放 80 端口"
    echo "  [2] Standalone HTTP — 需公网 TCP 80（本机 UFW 自动放行）"
    echo

    if [[ -n "${CF_TOKEN}" ]]; then
        CERT_MODE="cf"
        info "证书方式: Cloudflare DNS（来自 --cf-token）"
        validate_cf_token
        return
    fi

    if [[ "${ASSUME_YES}" == true ]]; then
        CERT_MODE="standalone"
        CF_TOKEN=""
        info "证书方式: Standalone（-y 且未传 --cf-token）"
        info "本机 UFW 将自动检测并放行所需端口"
        return
    fi

    while true; do
        prompt_read "请选择证书申请方式" choice "1"
        case "${choice}" in
            1|cf|CF|cloudflare|Cloudflare)
                CERT_MODE="cf"
                echo
                info "CF Token 需具备 Zone → DNS → Edit 权限"
                info "创建地址: https://dash.cloudflare.com/profile/api-tokens"
                while [[ -z "${CF_TOKEN}" ]]; do
                    prompt_secret "请输入 Cloudflare API Token" CF_TOKEN true
                    [[ -n "${CF_TOKEN}" ]] || warn "Token 不能为空"
                done
                validate_cf_token
                info "证书方式: Cloudflare DNS"
                break
                ;;
            2|standalone|Standalone|http)
                CERT_MODE="standalone"
                CF_TOKEN=""
                info "证书方式: Let's Encrypt Standalone"
                guard_standalone_port80
                break
                ;;
            *)
                warn "无效选项，请输入 1 或 2"
                ;;
        esac
    done
}

prompt_acme_email() {
    echo
    echo -e "${BOLD}--- 步骤 4: ACME 邮箱 ---${NC}"

    if [[ -n "${EMAIL}" ]]; then
        info "ACME 邮箱: ${EMAIL}（来自命令行）"
        return
    fi

    while true; do
        prompt_read "Let's Encrypt 证书邮箱" EMAIL "admin@${DOMAIN}"
        EMAIL="${EMAIL:-admin@${DOMAIN}}"
        if validate_email "${EMAIL}"; then
            break
        fi
        warn "邮箱格式无效: ${EMAIL}"
        EMAIL=""
    done
    info "ACME 邮箱: ${EMAIL}"
}

print_config_summary() {
    local cert_label dns_label action_label
    if [[ -n "${CF_TOKEN}" ]]; then
        cert_label="Cloudflare DNS"
    else
        cert_label="Standalone（需 80 端口）"
    fi
    if [[ "${DNS_CONFIRMED}" == true ]]; then
        dns_label="是"
    else
        dns_label="否 / 未确认"
    fi
    if [[ "${CHECK_ONLY}" == true ]]; then
        action_label="仅预检"
    else
        action_label="安装代理栈"
    fi

    echo
    echo -e "${BOLD}--- 配置摘要 ---${NC}"
    echo "  域名:     ${DOMAIN}"
    echo "  本机 IP:  ${PUBLIC_IPV4:-未知}"
    echo "  DNS 就绪: ${dns_label}"
    echo "  证书方式: ${cert_label}"
    echo "  ACME 邮箱: ${EMAIL}"
    echo "  操作:     ${action_label}"
    echo
}

confirm_proceed() {
    if [[ "${ASSUME_YES}" == true ]]; then
        return 0
    fi

    print_config_summary

    local msg="确认继续"
    [[ "${CHECK_ONLY}" == true ]] && msg="确认运行预检"
    prompt_yes_no "${msg}？" "y" || err "用户已取消"
    echo
}

prompt_install_options() {
    show_welcome
    check_root_early
    check_existing_install

    echo -e "${BOLD}--- 步骤 1: 域名 ---${NC}"
    PUBLIC_IPV4=$(get_public_ipv4)
    prompt_domain
    show_public_ip
    ensure_dns_lookup

    auto_check_dns
    check_dns_anomalies
    prompt_cert_method
    prompt_acme_email
    confirm_proceed
}

wait_dpkg_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [[ ${waited} -eq 0 ]]; then
            warn "正在等待 apt/dpkg 锁（可能正在自动更新）..."
        fi
        sleep 5
        waited=$((waited + 5))
        [[ ${waited} -lt 300 ]] || err "apt/dpkg 锁等待超时（300 秒）"
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
    err "需要 curl 或 wget。Debian/Ubuntu 执行: apt-get update && apt-get install -y curl wget ca-certificates"
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
        err "缺少 ${missing[*]} 且非 root，无法自动安装。请 root 运行或: apt-get install -y curl wget ca-certificates"
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        err "缺少 ${missing[*]}。本脚本仅支持 Debian/Ubuntu，请先手动安装 curl/wget"
    fi

    wait_dpkg_lock
    log "正在安装基础工具 (${missing[*]})..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl wget >/dev/null 2>&1 \
        || apt-get install -y ca-certificates curl wget \
        || err "安装 curl/wget 失败。请执行: apt-get update && apt-get install -y curl wget ca-certificates"

    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || err "安装后仍无 curl/wget 可用"
    log "基础工具就绪: $(command -v curl 2>/dev/null || echo 无curl) $(command -v wget 2>/dev/null || echo 无wget)"
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
    local host="$1" port="$2" proto="${3:-tcp}"
    if [[ "${proto}" == "tcp" ]]; then
        timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    else
        timeout 3 nc -u -z -w 2 "${host}" "${port}" 2>/dev/null && return 0
    fi
    return 1
}

# 检测 UFW 是否已放行某端口
ufw_port_allowed() {
    local port="$1"
    local proto="$2"
    local status_out

    command -v ufw >/dev/null 2>&1 || return 1
    status_out=$(ufw status 2>/dev/null) || return 1
    echo "${status_out}" | grep -E "${port}/${proto}" | grep -qiE 'ALLOW|ALLOW IN' && return 0
    return 1
}

# iptables 兜底放行（无 ufw 时）
iptables_allow_port() {
    local port="$1"
    local proto="$2"

    if ! command -v iptables >/dev/null 2>&1; then
        return 1
    fi
    if iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null; then
        return 0
    fi
    iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
}

# 检测本机防火墙并自动放行所需端口（云厂商防火墙无法远程修改）
ensure_firewall_ports() {
    local reset="${1:-false}"
    local spec port proto p opened=0 added=0

    log "正在检测本机防火墙端口..."

    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw >/dev/null 2>&1 || apt-get install -y ufw || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        if [[ "${reset}" == true ]]; then
            ufw --force reset >/dev/null 2>&1 || true
            ufw default deny incoming >/dev/null 2>&1 || true
            ufw default allow outgoing >/dev/null 2>&1 || true
        fi

        for spec in "22/tcp" "80/tcp" "443/tcp" "443/udp" "8443/tcp"; do
            port="${spec%/*}"
            proto="${spec#*/}"
            if ufw_port_allowed "${port}" "${proto}"; then
                opened=$((opened + 1))
                info "端口 ${port}/${proto} 已放行"
            else
                warn "端口 ${port}/${proto} 未放行，正在自动添加..."
                ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
                added=$((added + 1))
                log "已放行 ${port}/${proto}"
            fi
        done

        for p in $(seq 444 "${HY2_PORT_END}"); do
            if ufw_port_allowed "${p}" udp; then
                opened=$((opened + 1))
            else
                ufw allow "${p}/udp" >/dev/null 2>&1 || true
                added=$((added + 1))
            fi
        done

        ufw --force enable >/dev/null 2>&1 || true
        log "本机 UFW 就绪（已有 ${opened} 条，新增 ${added} 条）"
    else
        warn "未安装 ufw，尝试 iptables 放行..."
        for spec in "22/tcp" "80/tcp" "443/tcp" "443/udp" "8443/tcp"; do
            port="${spec%/*}"
            proto="${spec#*/}"
            iptables_allow_port "${port}" "${proto}"
        done
        for p in $(seq 444 "${HY2_PORT_END}"); do
            iptables_allow_port "${p}" udp
        done
        log "iptables 规则已更新"
    fi

    if [[ -z "${CF_TOKEN}" ]]; then
        info "Standalone 证书：若 80 仍不可达，请检查是否绑定了云防火墙安全组"
    fi
}

run_preflight() {
    PREFLIGHT_ERRORS=()
    PREFLIGHT_WARNS=()

    echo
    echo "============================================================"
    echo "  IFIM-Proxy 环境预检"
    echo "============================================================"
    info "域名: ${DOMAIN}"
    info "证书方式: $([[ -n "${CF_TOKEN}" ]] && echo 'Cloudflare DNS' || echo 'Let'\''s Encrypt Standalone（需 TCP 80）')"
    echo

    # root
    if [[ "${EUID}" -ne 0 ]]; then
        add_error "必须使用 root 运行"
    else
        info "用户: root 正常"
    fi

    # OS
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) info "系统: ${PRETTY_NAME:-未知} 正常" ;;
            *) add_warn "系统 ${PRETTY_NAME:-未知} 未充分测试（推荐 Debian/Ubuntu）" ;;
        esac
    else
        add_warn "无法检测系统版本"
    fi

    # arch
    case "$(uname -m)" in
        x86_64|aarch64) info "架构: $(uname -m) 正常" ;;
        *) add_error "不支持的架构: $(uname -m)（需要 x86_64 或 aarch64）" ;;
    esac

    # memory
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ ${mem_mb} -lt 512 ]]; then
        add_error "内存不足: ${mem_mb}MB（需要 >= 512MB）"
    elif [[ ${mem_mb} -lt 1024 ]]; then
        add_warn "内存 ${mem_mb}MB 偏低，双协议建议 >= 1GB"
    else
        info "内存: ${mem_mb}MB 正常"
    fi

    # disk
    local disk_free_mb
    disk_free_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [[ ${disk_free_mb} -lt 1024 ]]; then
        add_warn "磁盘剩余空间偏低: ${disk_free_mb}MB"
    else
        info "磁盘剩余: ${disk_free_mb}MB 正常"
    fi

    # dpkg lock
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        add_warn "apt/dpkg 被占用（安装时将自动等待）"
    else
        info "apt/dpkg 锁: 空闲"
    fi

    # network / public IP
    PUBLIC_IPV4=$(get_public_ipv4)
    PUBLIC_IPV6=$(get_public_ipv6)
    if [[ -n "${PUBLIC_IPV4}" ]]; then
        info "本机 IPv4: ${PUBLIC_IPV4}"
    else
        add_warn "无法检测公网 IPv4（DNS A 记录校验可能跳过）"
    fi
    if [[ -n "${PUBLIC_IPV6}" ]]; then
        info "本机 IPv6: ${PUBLIC_IPV6}"
    fi

    if check_connectivity 1.1.1.1 443 tcp; then
        info "出站 TCP 443: 正常"
    else
        add_warn "出站 TCP 443 不可达（可能影响 Reality 握手）"
    fi

    # DNS A record
    mapfile -t DNS_A < <(resolve_dns A || true)
    if [[ ${#DNS_A[@]} -eq 0 ]]; then
        add_error "未找到 ${DOMAIN} 的 DNS A 记录（请先添加 A 记录）"
    else
        info "DNS A: ${DNS_A[*]}"
        if [[ -n "${PUBLIC_IPV4}" ]]; then
            local matched=false
            for ip in "${DNS_A[@]}"; do
                [[ "${ip}" == "${PUBLIC_IPV4}" ]] && matched=true
            done
            if [[ "${matched}" == false ]]; then
                add_error "DNS A（${DNS_A[*]}）与本机 IPv4（${PUBLIC_IPV4}）不一致"
                add_warn "若使用 Cloudflare 橙色云，请改为灰色云朵（仅 DNS）"
            else
                info "DNS A 与本机 IPv4 一致"
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
            [[ "${matched6}" == true ]] && info "DNS AAAA 与本机 IPv6 一致" \
                || add_warn "DNS AAAA 与本机 IPv6 不一致（IPv6 可选）"
        fi
    fi

    # local port conflicts
    for spec in "443/tcp" "80/tcp"; do
        local p="${spec%/*}" proto="${spec#*/}"
        if port_in_use "${p}" "${proto}"; then
            add_warn "端口 ${p}/${proto} 已被占用（安装时将重新配置）"
        else
            info "端口 ${p}/${proto} 空闲"
        fi
    done

    # TLS 证书复用检测
    if [[ -n "${DOMAIN}" ]]; then
        local tls_crt="${INSTALL_DIR}/tls/${DOMAIN}.crt"
        local tls_key="${INSTALL_DIR}/tls/${DOMAIN}.key"
        if tls_cert_usable "${tls_crt}" "${tls_key}" "${DOMAIN}"; then
            info "TLS 证书: 已存在且有效，安装时将直接复用"
        elif acme_cert_usable "${DOMAIN}"; then
            info "TLS 证书: acme.sh 已有有效证书，安装时将自动安装"
        else
            info "TLS 证书: 未找到可用证书，安装时将向 Let's Encrypt 申请"
        fi
    fi

    # firewall / cloud firewall hints for standalone
    if [[ -z "${CF_TOKEN}" ]]; then
        add_warn "Standalone 证书需要公网可访问 TCP 80（本机 UFW 将自动放行）"
    else
        info "Cloudflare DNS 证书: 无需 80 端口"
    fi

    # required ports list
    info "所需端口: 22/tcp 80/tcp 443/tcp 443/udp 8443/tcp 444-${HY2_PORT_END}/udp"

    # download tools
    if command -v curl >/dev/null 2>&1; then
        info "下载工具: curl 正常"
    elif command -v wget >/dev/null 2>&1; then
        info "下载工具: wget 正常（未安装 curl）"
    else
        add_error "未找到 curl/wget（基础工具安装可能失败）"
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
        add_error "无法下载 sing-box v${SING_BOX_VERSION}（${sb_arch}，请检查版本或网络）"
    else
        info "sing-box v${SING_BOX_VERSION} 可下载"
    fi

    # summary
    echo
    echo "------------------------------------------------------------"
    if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
        fail "预检失败，共 ${#PREFLIGHT_ERRORS[@]} 个错误:"
        for e in "${PREFLIGHT_ERRORS[@]}"; do fail "  - ${e}"; done
        if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
            warn "警告:"
            for w in "${PREFLIGHT_WARNS[@]}"; do warn "  - ${w}"; done
        fi
        echo "============================================================"
        return 1
    fi

    if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
        warn "预检通过，但有 ${#PREFLIGHT_WARNS[@]} 条警告:"
        for w in "${PREFLIGHT_WARNS[@]}"; do warn "  - ${w}"; done
        if [[ "${ASSUME_YES}" == false && "${CHECK_ONLY}" == false ]]; then
            echo
            prompt_yes_no "是否继续安装？" "y" || err "安装已取消"
        fi
    else
        log "预检: 全部通过"
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
    log "正在安装系统依赖..."
    apt-get update -qq
    apt-get install -y -qq curl wget jq openssl ca-certificates ufw nginx iptables dnsutils netcat-openbsd qrencode \
        >/dev/null 2>&1 \
        || apt-get install -y curl wget jq openssl ca-certificates ufw nginx iptables dnsutils netcat-openbsd qrencode
}

apply_sysctl() {
    log "正在应用内核网络优化..."
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
    log "正在安装 sing-box ${SING_BOX_VERSION}..."
    mkdir -p "${INSTALL_DIR}/sing-box"
    local arch sb_arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) sb_arch="amd64" ;;
        aarch64) sb_arch="arm64" ;;
        *) err "不支持的架构: ${arch}" ;;
    esac
    local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${sb_arch}.tar.gz"
    http_get "${sb_url}" | tar -xzf - -C /tmp
    install -m 755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${sb_arch}/sing-box" "${INSTALL_DIR}/sing-box/sing-box"
    ln -sf "${INSTALL_DIR}/sing-box/sing-box" /usr/local/bin/sing-box
}

# 证书是否匹配域名且未过期（默认至少剩余 1 天）
cert_domain_matches() {
    local crt="$1"
    local domain="$2"

    openssl x509 -in "${crt}" -noout -ext subject_alt_name 2>/dev/null \
        | tr ',' '\n' | grep -q "DNS:${domain}" && return 0
    openssl x509 -in "${crt}" -noout -subject 2>/dev/null \
        | grep -qE "CN\s*=\s*${domain}" && return 0
    return 1
}

tls_cert_usable() {
    local crt="$1"
    local key="$2"
    local domain="$3"
    local min_secs="${4:-86400}"

    [[ -f "${crt}" && -f "${key}" ]] || return 1
    openssl x509 -in "${crt}" -noout 2>/dev/null || return 1
    openssl pkey -in "${key}" -noout 2>/dev/null || return 1
    openssl x509 -in "${crt}" -noout -checkend "${min_secs}" 2>/dev/null || return 1
    cert_domain_matches "${crt}" "${domain}"
}

acme_cert_paths() {
    local domain="$1"
    local acme_dir="${HOME}/.acme.sh/${domain}_ecc"
    local key="${acme_dir}/${domain}.key"
    local crt="${acme_dir}/fullchain.cer"

    [[ -f "${crt}" ]] || crt="${acme_dir}/${domain}.cer"
    echo "${crt}|${key}|${acme_dir}"
}

acme_cert_usable() {
    local domain="$1"
    local paths crt key

    paths=$(acme_cert_paths "${domain}")
    crt="${paths%%|*}"
    paths="${paths#*|}"
    key="${paths%%|*}"

    tls_cert_usable "${crt}" "${key}" "${domain}"
}

ensure_acme_sh() {
    if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
        http_get "https://get.acme.sh" | sh -s email="${EMAIL}" >/dev/null 2>&1
    fi
    # shellcheck source=/dev/null
    source "${HOME}/.acme.sh/acme.sh.env" 2>/dev/null || true
    "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

install_tls_cert_files() {
    local tls_dir="${INSTALL_DIR}/tls"
    local reload_cmd="true"

    # 证书复制完成后重载服务；安装早期 sing-box 可能尚未创建，需容错避免 acme.sh 报 Reload error
    if [[ -f "${INSTALL_DIR}/scripts/renew-hook.sh" ]]; then
        reload_cmd="/bin/bash ${INSTALL_DIR}/scripts/renew-hook.sh || true"
    else
        reload_cmd="systemctl reload nginx 2>/dev/null || true; systemctl restart sing-box 2>/dev/null || true"
    fi

    "${HOME}/.acme.sh/acme.sh" --install-cert -d "${DOMAIN}" --ecc \
        --key-file "${tls_dir}/${DOMAIN}.key" \
        --fullchain-file "${tls_dir}/${DOMAIN}.crt" \
        --reloadcmd "${reload_cmd}"
}

issue_tls_cert() {
    local tls_dir="${INSTALL_DIR}/tls"
    local crt="${tls_dir}/${DOMAIN}.crt"
    local key="${tls_dir}/${DOMAIN}.key"
    local end_date

    mkdir -p "${tls_dir}"

    if tls_cert_usable "${crt}" "${key}" "${DOMAIN}"; then
        end_date=$(openssl x509 -in "${crt}" -noout -enddate 2>/dev/null | cut -d= -f2-)
        log "检测到有效 TLS 证书，跳过申请（到期 ${end_date}）"
        write_cert_meta
        return 0
    fi

    ensure_acme_sh

    if acme_cert_usable "${DOMAIN}"; then
        log "acme.sh 已有 ${DOMAIN} 有效证书，直接安装使用"
        install_tls_cert_files
        write_cert_meta
        end_date=$(openssl x509 -in "${crt}" -noout -enddate 2>/dev/null | cut -d= -f2-)
        info "TLS 证书已就绪（到期 ${end_date}）"
        return 0
    fi

    log "未找到可用证书，正在向 Let's Encrypt 申请..."
    if [[ -n "${CF_TOKEN}" ]]; then
        CERT_MODE="cf"
        export CF_Token="${CF_TOKEN}"
        "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server letsencrypt
    else
        CERT_MODE="standalone"
        systemctl stop nginx 2>/dev/null || true
        "${HOME}/.acme.sh/acme.sh" --issue --standalone -d "${DOMAIN}" --keylength ec-256 --server letsencrypt \
            --pre-hook "systemctl stop nginx 2>/dev/null || true" \
            --post-hook "systemctl start nginx 2>/dev/null || true"
        systemctl start nginx 2>/dev/null || true
    fi

    install_tls_cert_files
    write_cert_meta
    end_date=$(openssl x509 -in "${crt}" -noout -enddate 2>/dev/null | cut -d= -f2-)
    log "TLS 证书申请完成（到期 ${end_date}）"
}

write_cert_meta() {
    local mode="standalone"
    local existing_env="${INSTALL_DIR}/cert.env"

    if [[ -n "${CF_TOKEN}" ]]; then
        mode="cf"
    elif [[ -f "${existing_env}" ]]; then
        # 复用已有证书时保留原 CF 续签配置
        # shellcheck source=/dev/null
        source "${existing_env}"
        if [[ "${CERT_MODE:-}" == "cf" && -f "${INSTALL_DIR}/cf-token" ]]; then
            mode="cf"
        fi
    fi
    CERT_MODE="${mode}"

    cat >"${INSTALL_DIR}/cert.env" <<EOF
DOMAIN="${DOMAIN}"
CERT_MODE="${mode}"
EMAIL="${EMAIL}"
EOF
    chmod 644 "${INSTALL_DIR}/cert.env"

    if [[ "${mode}" == "cf" ]]; then
        if [[ -n "${CF_TOKEN}" ]]; then
            printf '%s' "${CF_TOKEN}" >"${INSTALL_DIR}/cf-token"
            chmod 600 "${INSTALL_DIR}/cf-token"
        elif [[ ! -f "${INSTALL_DIR}/cf-token" ]]; then
            warn "CF 证书模式但缺少 cf-token，自动续签可能失败"
        fi
    else
        rm -f "${INSTALL_DIR}/cf-token"
    fi
}

setup_cert_renewal() {
    log "正在配置 TLS 自动续签..."
    install_tls_cert_files
    write_cert_meta
    setup_cron
    info "证书自动续签: 每天 03:00 / 15:00 检查，临近到期时自动续签"
}

write_singbox_config() {
    log "正在写入 sing-box 配置..."
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
          "short_id": ["", "${REALITY_SHORT_ID}"]
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
    sing-box check -c "${INSTALL_DIR}/config.json" || err "sing-box 配置校验失败"
}

setup_nginx() {
    log "正在配置 Nginx 伪装站..."
    write_nginx_config
}

write_nginx_config() {
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
EOF
    if [[ -n "${SUB_PANEL_TOKEN}" ]]; then
        cat >>/etc/nginx/conf.d/stable-proxy.conf <<EOF
    location = /s/${SUB_PANEL_TOKEN}/sub {
        alias ${INSTALL_DIR}/sub.b64;
        default_type text/plain;
        charset utf-8;
        add_header Profile-Update-Interval "24";
    }
    location = /s/${SUB_PANEL_TOKEN}/clash.yaml {
        alias ${WEB_ROOT}/panel/clash.yaml;
        default_type text/yaml;
        charset utf-8;
    }
    location /s/${SUB_PANEL_TOKEN}/ {
        alias ${WEB_ROOT}/panel/;
        index index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }
EOF
    fi
    cat >>/etc/nginx/conf.d/stable-proxy.conf <<'EOF'
}
EOF
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
    nginx -t
}

generate_panel_qrcodes() {
    local panel_dir="$1"
    local sub_url="$2"
    local reality_link="$3"
    local hy2_link="$4"

    if ! command -v qrencode >/dev/null 2>&1; then
        warn "未安装 qrencode，订阅页二维码将不可用"
        return 0
    fi

    qrencode -o "${panel_dir}/qr-sub.png" -s 5 -m 1 "${sub_url}"
    qrencode -o "${panel_dir}/qr-reality.png" -s 5 -m 1 "${reality_link}"
    qrencode -o "${panel_dir}/qr-hy2.png" -s 5 -m 1 "${hy2_link}"
    chmod 644 "${panel_dir}"/qr-*.png
    log "订阅页二维码已生成"
}

generate_subscribe_web() {
    local panel_dir="${WEB_ROOT}/panel"
    local sub_url clash_url

    SUB_PANEL_TOKEN=$(openssl rand -hex 16)
    PANEL_URL="https://${DOMAIN}:8443/s/${SUB_PANEL_TOKEN}/"
    sub_url="${PANEL_URL}sub"
    clash_url="${PANEL_URL}clash.yaml"

    printf '%s\n%s' "${REALITY_LINK}" "${HY2_LINK}" | base64 -w0 >"${INSTALL_DIR}/sub.b64"
    chmod 644 "${INSTALL_DIR}/sub.b64"

    mkdir -p "${panel_dir}"
    fetch_asset "assets/subscribe-panel.html" "${panel_dir}/index.html"
    cp "${INSTALL_DIR}/clash-meta.yaml" "${panel_dir}/clash.yaml"
    chmod 644 "${panel_dir}/clash.yaml" "${panel_dir}/index.html"

    cat >"${panel_dir}/config.json" <<EOF
{
  "domain": "${DOMAIN}",
  "panelUrl": "${PANEL_URL}",
  "subUrl": "${sub_url}",
  "clashUrl": "${clash_url}",
  "realityLink": "${REALITY_LINK}",
  "hy2Link": "${HY2_LINK}",
  "created": "$(date -u +"%Y-%m-%d %H:%M UTC")",
  "version": "${SCRIPT_VERSION}"
}
EOF
    chmod 644 "${panel_dir}/config.json"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${panel_dir}/config.json" "${panel_dir}/index.html" "${SCRIPT_VERSION}" <<'PY'
import json, pathlib, sys
cfg_path, html_path, script_version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
html = html_path.read_text(encoding="utf-8")
html = html.replace("__SCRIPT_VERSION__", cfg.get("version") or script_version)
html = html.replace("__PANEL_CONFIG__", json.dumps(cfg, ensure_ascii=False))
html_path.write_text(html, encoding="utf-8")
PY
    elif command -v jq >/dev/null 2>&1; then
        local cfg_compact
        cfg_compact=$(jq -c . "${panel_dir}/config.json")
        sed -i "s|__SCRIPT_VERSION__|${SCRIPT_VERSION}|g" "${panel_dir}/index.html"
        sed -i "s|__PANEL_CONFIG__|${cfg_compact}|g" "${panel_dir}/index.html"
    else
        warn "无法内嵌订阅页配置（缺少 python3/jq），一键导入可能不可用"
    fi

    generate_panel_qrcodes "${panel_dir}" "${sub_url}" "${REALITY_LINK}" "${HY2_LINK}"

    write_nginx_config
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
}

setup_systemd() {
    log "正在创建 systemd 服务..."
    cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box (IFIM-Proxy)
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
    systemctl restart sing-box
    systemctl start stable-proxy-port-hopping 2>/dev/null \
        || "${INSTALL_DIR}/scripts/port-hopping.sh" 443 443 "${HY2_PORT_END}" || true
}

apply_port_hopping() {
    log "正在配置 UDP 端口跳跃..."
    systemctl start stable-proxy-port-hopping 2>/dev/null \
        || "${INSTALL_DIR}/scripts/port-hopping.sh" 443 443 "${HY2_PORT_END}" || true
}

setup_firewall() {
    if [[ "${RESET_FIREWALL:-false}" == true ]]; then
        warn "正在重置 UFW 规则（--reset-firewall）..."
        ensure_firewall_ports true
    else
        ensure_firewall_ports false
    fi
}

setup_cron() {
    (crontab -l 2>/dev/null | grep -vE 'stable-proxy-stack|stable-proxy'; \
     echo "0 3,15 * * * /bin/bash ${INSTALL_DIR}/scripts/renew-cert.sh >> ${INSTALL_DIR}/renew.log 2>&1 # stable-proxy-stack"; \
     echo "*/5 * * * * /bin/bash ${INSTALL_DIR}/scripts/healthcheck.sh # stable-proxy-stack") \
    | crontab -
}

verify_install() {
    local ok=true i

    echo
    log "正在验证安装结果..."

    for i in $(seq 1 10); do
        if ss -tlnpH 'sport = :443' 2>/dev/null | grep -q sing-box \
            && ss -ulnpH 'sport = :443' 2>/dev/null | grep -q sing-box; then
            break
        fi
        [[ ${i} -eq 10 ]] || sleep 1
    done

    for svc in sing-box nginx stable-proxy-port-hopping; do
        if systemctl is-active --quiet "${svc}"; then
            info "服务 ${svc}: 运行中"
        else
            fail "服务 ${svc}: 未运行"
            ok=false
        fi
    done
    if ss -tlnpH 'sport = :443' 2>/dev/null | grep -q sing-box; then
        info "TCP 443 (Reality): 监听正常"
    else
        fail "TCP 443 (Reality): 未监听"
        ok=false
    fi
    if ss -ulnpH 'sport = :443' 2>/dev/null | grep -q sing-box; then
        info "UDP 443 (hy2): 监听正常"
    else
        fail "UDP 443 (hy2): 未监听"
        ok=false
    fi
    if [[ -f "${INSTALL_DIR}/tls/${DOMAIN}.crt" ]]; then
        info "TLS 证书: 正常（到期 $(openssl x509 -in "${INSTALL_DIR}/tls/${DOMAIN}.crt" -noout -enddate 2>/dev/null | cut -d= -f2)）"
    else
        fail "TLS 证书: 缺失"
        ok=false
    fi
    if [[ -f "${INSTALL_DIR}/cert.env" ]] && crontab -l 2>/dev/null | grep -q 'renew-cert.sh'; then
        info "TLS 自动续签: 已配置（每天 03:00 / 15:00）"
    else
        fail "TLS 自动续签: 未配置"
        ok=false
    fi
    [[ "${ok}" == true ]] || err "安装后验证失败，请查看 journalctl -u sing-box -n 50"
}

print_links() {
    REALITY_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision#reality-main"
    HY2_LINK="hysteria2://${UUID}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&mport=443-${HY2_PORT_END}&peer=${DOMAIN}&insecure=0&sni=${DOMAIN}&alpn=h3#hy2-backup"

    cat >"${INSTALL_DIR}/subscribe.txt" <<EOF
# IFIM-Proxy
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
REALITY_SHORT_ID=${REALITY_SHORT_ID}
HY2_PORT_END=${HY2_PORT_END}
SERVER_IPV4=${PUBLIC_IPV4:-unknown}
EOF
    chmod 600 "${INSTALL_DIR}/credentials.txt"

    bash "${INSTALL_DIR}/scripts/render-clash.sh"

    generate_subscribe_web

    cat >>"${INSTALL_DIR}/credentials.txt" <<EOF
PANEL_URL=${PANEL_URL}
SUB_PANEL_TOKEN=${SUB_PANEL_TOKEN}
EOF
    chmod 600 "${INSTALL_DIR}/credentials.txt"

    echo
    echo "============================================================"
    echo -e "${GREEN}  安装完成！${NC}"
    echo "============================================================"
    echo
    echo "  订阅网页: ${PANEL_URL}"
    echo
    echo "  配置目录: ${INSTALL_DIR}/"
    echo "============================================================"

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${PANEL_URL}" >/dev/null 2>&1 &
    fi
}

# ── Main ────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

ensure_bootstrap_tools
reexec_if_piped
show_script_version
check_script_version
prompt_install_options

EMAIL="${EMAIL:-admin@${DOMAIN}}"

if [[ "${SKIP_CHECK}" == false ]]; then
    run_preflight || exit 1
fi

if [[ "${CHECK_ONLY}" == true ]]; then
    echo
    log "预检完成，环境看起来可以安装。"
    echo
    info "开始安装请去掉 --check-only，重新运行:"
    if [[ -n "${CF_TOKEN}" ]]; then
        echo "  bash install.sh --domain ${DOMAIN} --cf-token <TOKEN> --email ${EMAIL}"
    else
        echo "  bash install.sh --domain ${DOMAIN} --email ${EMAIL}"
    fi
    echo
    echo "或直接运行: bash install.sh"
    exit 0
fi

trap on_install_error ERR

UUID=$(cat /proc/sys/kernel/random/uuid)
OBFS_PASS=$(openssl rand -hex 8)
log "UUID: ${UUID}"

install_packages
apply_sysctl
install_singbox_binary

REALITY_KEYS=$("${INSTALL_DIR}/sing-box/sing-box" generate reality-keypair)
REALITY_PRIV=$(echo "${REALITY_KEYS}" | awk '/PrivateKey/ {print $2}')
REALITY_PUB=$(echo "${REALITY_KEYS}" | awk '/PublicKey/ {print $2}')
[[ -n "${REALITY_PRIV}" && -n "${REALITY_PUB}" ]] || err "Reality 密钥生成失败"

ensure_firewall_ports false
issue_tls_cert

mkdir -p "${INSTALL_DIR}/scripts" "${WEB_ROOT}"
fetch_asset "scripts/common.env" "${INSTALL_DIR}/scripts/common.env"
fetch_asset "scripts/render-clash.sh" "${INSTALL_DIR}/scripts/render-clash.sh"
fetch_asset "scripts/port-hopping.sh" "${INSTALL_DIR}/scripts/port-hopping.sh"
fetch_asset "scripts/healthcheck.sh" "${INSTALL_DIR}/scripts/healthcheck.sh"
fetch_asset "scripts/renew-hook.sh" "${INSTALL_DIR}/scripts/renew-hook.sh"
fetch_asset "scripts/renew-cert.sh" "${INSTALL_DIR}/scripts/renew-cert.sh"
fetch_asset "scripts/refresh-clash.sh" "${INSTALL_DIR}/scripts/refresh-clash.sh"
fetch_asset "scripts/refresh-panel.sh" "${INSTALL_DIR}/scripts/refresh-panel.sh"
fetch_asset "scripts/update-stack.sh" "${INSTALL_DIR}/scripts/update-stack.sh"
fetch_asset "scripts/sync-version.sh" "${INSTALL_DIR}/scripts/sync-version.sh"
fetch_asset "assets/index.html" "${WEB_ROOT}/index.html"

write_singbox_config
setup_nginx
setup_firewall
setup_systemd
setup_cert_renewal
apply_port_hopping
verify_install
print_links
