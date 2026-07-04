# IFIM-Proxy

在 VPS 上一键部署双协议代理（原 stable-proxy-stack，仓库已更名为 IFIM-Proxy，旧地址仍可用）：

- **主力**：VLESS + Reality + Vision（TCP 443，稳定）
- **备用**：Hysteria2 + obfs（UDP 443，速度）

---

## 安装前准备

1. **系统**：Debian 11+ / Ubuntu 20.04+，root 登录
2. **域名**：有一个域名，并能修改 DNS
3. **DNS**：添加 A 记录，指向 VPS 公网 IP  
   - 用 Cloudflare 时选 **灰色云朵**（仅 DNS），不要橙色代理
4. **防火墙**：
   - **本机 UFW**：脚本会**自动检测**端口，未放行则**自动添加**（22/80/443 等）
   - **云防火墙**：仅在你绑定了安全组且拦截 80 时才需手动放行；Vultr 默认无云防火墙

> 若不想在云防火墙开 80 端口，安装时选 **Cloudflare DNS 证书**（需 CF API Token）。

---

## 一键安装

SSH 登录 VPS，粘贴执行（**推荐**：按 GitHub 最新 commit 拉取，彻底绕过 CDN 缓存）：

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
bash -c 'R=CNLiuBei/IFIM-Proxy; S=$(curl -fsSL https://api.github.com/repos/$R/commits/main | sed -n "s/.*\"sha\": \"\\([a-f0-9]\\{40\\}\\)\".*/\\1/p" | head -1); curl -fsSL "https://raw.githubusercontent.com/$R/${S}/install.sh" | bash'
```

> 也可将 `R=CNLiuBei/IFIM-Proxy` 换成 `R=CNLiuBei/stable-proxy-stack`（同一仓库）。

即使误用了旧缓存脚本，启动后也会**自动检测并升级到最新版**再安装。

安装开始时会显示脚本版本（当前 **v0.0.17**）。

重装时若已有有效 TLS 证书（本机或 acme.sh），将自动复用，不会重复向 Let's Encrypt 申请。证书临近到期时，每天 **03:00 / 15:00** 自动续签并重载服务。

按中文提示操作：输入域名 → 自动检测 DNS → 选证书方式 → 确认安装。

---

## 安装完成后

终端仅显示 **订阅网页链接**，节点链接与二维码在网页内查看：

```
https://你的域名:8443/s/随机token/
```

订阅页为 **Apple 风格一页式布局**：桌面端一屏展示订阅链接、Reality / Hysteria2 单节点链接、二维码与客户端一键导入按钮。

链接同时保存在 `/etc/stable-proxy-stack/credentials.txt`。

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 证书申请失败 | 检查 DNS 是否生效；CF 是否灰色云朵；Standalone 是否放了 80 端口 |
| 证书会自动续签吗 | 会。每天 03:00/15:00 检查，临近到期自动续签；日志见 `/etc/stable-proxy-stack/renew.log` |
| Clash 只导入 1 个节点 | 运行 `bash /etc/stable-proxy-stack/scripts/refresh-clash.sh` 更新配置后重新导入 |
| 订阅页没有变化 / 样式仍是旧版 | 在 **VPS 上**执行：`bash /etc/stable-proxy-stack/scripts/refresh-panel.sh` |
| 更新脚本但不重装 | `bash /etc/stable-proxy-stack/scripts/update-stack.sh -y`（拉取最新 scripts 并刷新面板 + Clash） |
| 只有 22 能连 | 去云厂商面板开防火墙，或改用 CF DNS 证书 |
| 想先检查环境 | 命令末尾加 `--check-only` |
| 重装 / 覆盖 | 脚本会提示确认；完全卸载见下方 |

---

## 其他用法

**仅预检，不安装**

```bash
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/IFIM-Proxy/main/install.sh | bash -s -- --check-only
```

**非交互（适合脚本）**

```bash
# Cloudflare 证书（推荐）
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/IFIM-Proxy/main/install.sh | bash -s -- \
  --domain your.domain.com --cf-token YOUR_TOKEN -y

# Standalone 证书（需云防火墙 80 端口）
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/IFIM-Proxy/main/install.sh | bash -s -- \
  --domain your.domain.com -y
```

**克隆仓库安装**

```bash
git clone https://github.com/CNLiuBei/IFIM-Proxy.git
cd IFIM-Proxy && bash install.sh
```

**本地预览订阅页样式**（无需 VPS）

```bash
cd assets/preview && python3 -m http.server 8877
# 浏览器打开 http://localhost:8877/panel.html
```

常用参数：`--domain` `--email` `--cf-token` `--check-only` `-y`  
完整列表：`bash install.sh --help`

---

## 卸载

```bash
bash uninstall.sh
```

---

## 免责声明

仅供学习与技术研究，请遵守当地法律法规。

MIT License
