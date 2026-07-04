#!/usr/bin/env bash
# 刷新订阅页 HTML + 二维码（已安装机器修复用）
set -euo pipefail

INSTALL_DIR="/etc/stable-proxy-stack"
WEB_ROOT="/var/www/stable-proxy"
PANEL_DIR="${WEB_ROOT}/panel"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main}"

[[ -f "${PANEL_DIR}/config.json" ]] || { echo "config.json 不存在: ${PANEL_DIR}/config.json"; exit 1; }

sub_url=$(jq -r .subUrl "${PANEL_DIR}/config.json")
reality_link=$(jq -r .realityLink "${PANEL_DIR}/config.json")
hy2_link=$(jq -r .hy2Link "${PANEL_DIR}/config.json")

command -v qrencode >/dev/null 2>&1 || apt-get install -y -qq qrencode >/dev/null 2>&1 || apt-get install -y qrencode

curl -fsSL "${REPO_BASE}/assets/subscribe-panel.html" -o "${PANEL_DIR}/index.html"

python3 - "${PANEL_DIR}/config.json" "${PANEL_DIR}/index.html" <<'PY'
import json, pathlib, sys
cfg_path, html_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
html = html_path.read_text(encoding="utf-8")
html = html.replace("__PANEL_CONFIG__", json.dumps(cfg, ensure_ascii=False))
html_path.write_text(html, encoding="utf-8")
PY

qrencode -o "${PANEL_DIR}/qr-sub.png" -s 5 -m 1 "${sub_url}"
qrencode -o "${PANEL_DIR}/qr-reality.png" -s 5 -m 1 "${reality_link}"
qrencode -o "${PANEL_DIR}/qr-hy2.png" -s 5 -m 1 "${hy2_link}"
chmod 644 "${PANEL_DIR}/index.html" "${PANEL_DIR}"/qr-*.png

echo "订阅页已刷新: $(jq -r .panelUrl "${PANEL_DIR}/config.json")"
