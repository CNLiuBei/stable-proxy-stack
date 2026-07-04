#!/usr/bin/env bash
# 从 GitHub 更新已安装机器上的脚本（无需重装）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.env
source "${SCRIPT_DIR}/common.env"

TS="$(date +%s)"
REFRESH_PANEL=false
REFRESH_CLASH=false

usage() {
    cat <<EOF
用法: bash update-stack.sh [选项]

从 GitHub 拉取最新 scripts/ 到 ${INSTALL_DIR}/scripts/

选项:
  --refresh-panel   更新后刷新订阅页 HTML + 二维码
  --refresh-clash   更新后重新生成 Clash 配置
  -y                全部执行（更新 + refresh-panel + refresh-clash）
  -h, --help        显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh-panel) REFRESH_PANEL=true; shift ;;
        --refresh-clash) REFRESH_CLASH=true; shift ;;
        -y) REFRESH_PANEL=true; REFRESH_CLASH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知选项: $1"; usage; exit 1 ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }
[[ -d "${INSTALL_DIR}" ]] || { echo "未找到 ${INSTALL_DIR}，请先安装"; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "缺少 curl"; exit 1; }

sha=$(curl -fsSL --max-time 15 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPO}/commits/main" \
    | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)

branch="main"
[[ -n "${sha}" ]] && branch="${sha}"

scripts=(
    common.env
    render-clash.sh
    refresh-clash.sh
    regenerate-nodes.sh
    show-panel.sh
    refresh-panel.sh
    healthcheck.sh
    renew-cert.sh
    renew-hook.sh
    port-hopping.sh
    update-stack.sh
    sync-version.sh
)

mkdir -p "${INSTALL_DIR}/scripts"
for name in "${scripts[@]}"; do
    url="https://raw.githubusercontent.com/${GITHUB_REPO}/${branch}/scripts/${name}?t=${TS}"
    dest="${INSTALL_DIR}/scripts/${name}"
    if ! curl -fsSL -H "Cache-Control: no-cache" "${url}" -o "${dest}"; then
        echo "下载失败: ${name}"
        exit 1
    fi
    if [[ ! -s "${dest}" ]]; then
        echo "下载为空: ${name}"
        exit 1
    fi
    chmod 755 "${dest}"
    echo "已更新: ${dest}"
done

remote_ver=$(curl -fsSL -H "Cache-Control: no-cache" \
    "https://raw.githubusercontent.com/${GITHUB_REPO}/${branch}/install.sh?t=${TS}" \
    | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1)

if [[ -n "${remote_ver}" ]]; then
    echo "${remote_ver}" >"${INSTALL_DIR}/.stack-version"
    echo "远端版本: v${remote_ver}"
fi

if [[ "${REFRESH_PANEL}" == true || "${REFRESH_CLASH}" == true ]]; then
    if [[ -f "${INSTALL_DIR}/scripts/regenerate-nodes.sh" ]]; then
        bash "${INSTALL_DIR}/scripts/regenerate-nodes.sh"
    else
        [[ "${REFRESH_CLASH}" == true && -f "${INSTALL_DIR}/scripts/refresh-clash.sh" ]] \
            && bash "${INSTALL_DIR}/scripts/refresh-clash.sh"
        [[ "${REFRESH_PANEL}" == true && -f "${INSTALL_DIR}/scripts/refresh-panel.sh" ]] \
            && bash "${INSTALL_DIR}/scripts/refresh-panel.sh"
    fi
fi

if [[ -f "${INSTALL_DIR}/scripts/show-panel.sh" ]]; then
    chmod 755 "${INSTALL_DIR}/scripts/show-panel.sh"
    cat >/usr/local/bin/ifim-panel <<EOF
#!/usr/bin/env bash
exec bash ${INSTALL_DIR}/scripts/show-panel.sh "\$@"
EOF
    chmod 755 /usr/local/bin/ifim-panel
fi

echo "脚本更新完成（${GITHUB_REPO}@${branch:0:7}）"
