# stable-proxy-stack

在 VPS 上一键部署双协议代理：

- **主力**：VLESS + Reality + Vision（TCP 443，稳定）
- **备用**：Hysteria2 + obfs（UDP 443，速度）

---

## 安装前准备

1. **系统**：Debian 11+ / Ubuntu 20.04+，root 登录
2. **域名**：有一个域名，并能修改 DNS
3. **DNS**：添加 A 记录，指向 VPS 公网 IP  
   - 用 Cloudflare 时选 **灰色云朵**（仅 DNS），不要橙色代理
4. **防火墙**（两层，都要管）：
   - **云防火墙**（Vultr/AWS 控制面板）：放行 `22, 80, 443/tcp, 443/udp, 8443, 444-450/udp`
   - **本机防火墙**：脚本会自动用 UFW 放行，无需手动配置

> 若不想在云防火墙开 80 端口，安装时选 **Cloudflare DNS 证书**（需 CF API Token）。

---

## 一键安装

SSH 登录 VPS，粘贴执行：

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash
```

按中文提示操作：输入域名 → 自动检测 DNS → 选证书方式 → 确认安装。

---

## 安装完成后

终端会输出 **订阅网页链接**（含二维码、一键导入按钮），形如：

```
https://你的域名:8443/s/随机token/
```

同时保存到 `/etc/stable-proxy-stack/credentials.txt` 的 `PANEL_URL` 字段。

本地文件：

```
/etc/stable-proxy-stack/subscribe.txt      # 节点链接
/etc/stable-proxy-stack/credentials.txt  # 密钥 + 订阅网页
/etc/stable-proxy-stack/clash-meta.yaml  # Clash Meta 配置
```

**客户端**：打开订阅网页扫码或点一键导入；Clash Meta / v2rayNG / Shadowrocket / Sing-box 等均支持。

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 证书申请失败 | 检查 DNS 是否生效；CF 是否灰色云朵；Standalone 是否放了 80 端口 |
| 只有 22 能连 | 去云厂商面板开防火墙，或改用 CF DNS 证书 |
| 想先检查环境 | 命令末尾加 `--check-only` |
| 重装 / 覆盖 | 脚本会提示确认；完全卸载见下方 |

---

## 其他用法

**仅预检，不安装**

```bash
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- --check-only
```

**非交互（适合脚本）**

```bash
# Cloudflare 证书（推荐）
curl -fsSL .../install.sh | bash -s -- \
  --domain your.domain.com --cf-token YOUR_TOKEN -y

# Standalone 证书（需云防火墙 80 端口）
curl -fsSL .../install.sh | bash -s -- \
  --domain your.domain.com -y
```

**克隆仓库安装**

```bash
git clone https://github.com/CNLiuBei/stable-proxy-stack.git
cd stable-proxy-stack && bash install.sh
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
