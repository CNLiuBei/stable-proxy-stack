#!/usr/bin/env bash
# 从 git commit 自动生成并写入 SCRIPT_VERSION（本地或 CI 调用，无需手改版本号）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT}/install.sh"
README="${ROOT}/README.md"

[[ -d "${ROOT}/.git" ]] || { echo "不在 git 仓库内，跳过"; exit 0; }

full_sha=$(git -C "${ROOT}" rev-parse HEAD)
short_sha=$(git -C "${ROOT}" rev-parse --short HEAD)
date_ver=$(git -C "${ROOT}" log -1 --format=%cs HEAD | tr '-' '.')
VER="${date_ver}+${short_sha}"

if [[ ! -f "${INSTALL_SH}" ]]; then
    echo "install.sh 不存在"
    exit 1
fi

# macOS / Linux sed -i
sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

if grep -q '^# @commit:' "${INSTALL_SH}"; then
    sed_inplace "s/^# @commit: .*/# @commit: ${full_sha}/" "${INSTALL_SH}"
else
    sed_inplace "5i\\
# @commit: ${full_sha}
" "${INSTALL_SH}"
fi

sed_inplace "s/^SCRIPT_VERSION=\".*\"/SCRIPT_VERSION=\"${VER}\"/" "${INSTALL_SH}"

if [[ -f "${README}" ]]; then
    if grep -q 'push 到 main 后由 CI 自动同步' "${README}"; then
        : # 说明性文字，无需替换固定版本号
    else
        sed_inplace "s/当前 \*\*v[^*]*\*\*/当前 **v${VER}**/" "${README}"
    fi
fi

preview_cfg="${ROOT}/assets/preview/config.json"
if [[ -f "${preview_cfg}" ]] && command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg v "${VER}" '.version = $v' "${preview_cfg}" >"${tmp}"
    mv "${tmp}" "${preview_cfg}"
fi

echo "版本已同步: ${VER} (${full_sha:0:7})"
