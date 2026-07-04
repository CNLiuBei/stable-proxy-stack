# stable-proxy-stack

一键部署 **VLESS + Reality + Vision（稳定主力）** + **Hysteria2 + obfs（速度备用）** 双协议代理栈。

适合：稳定优先、速度其次、不换机房也要尽量优化防封的场景。

## 架构

```
TCP 443  →  VLESS + Reality + Vision   主力（稳定）
UDP 443  →  Hysteria2 + Salamander    备用（速度）
TCP 8443 →  Nginx 伪装博客
UDP 443-450 → 端口跳跃（hy2 备用）
```

## 系统要求

- Debian 11+ / Ubuntu 20.04+
- root 权限
- 域名已解析到 VPS IP
- 开放端口：22, 80, 443/tcp, 443/udp, 8443, 444-450/udp

> **极简镜像说明**：Debian / Ubuntu 自带 `apt`，但部分 VPS 未预装 `curl`。下方一键命令已在前缀加入安装步骤；脚本内部也会自动检测并补装 `curl` / `wget`。
>
> 单独安装下载工具：
>
> ```bash
> apt-get update && apt-get install -y curl wget ca-certificates
> ```

## 一键安装

在 **VPS 上** SSH 登录后复制粘贴执行。`apt` 为系统自带，无需单独安装。

### 交互式安装（推荐）

运行后按提示输入域名，确认 DNS 是否已解析，选择是否用 Cloudflare 申请证书：

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash
```

交互流程（4 步 + 确认）：

```
============================================================
  stable-proxy-stack — interactive setup
============================================================

--- Step 1: Domain ---
Enter your domain (e.g. jp.example.com): jp.example.com

--- Step 2: DNS ---
  jp.example.com  →  45.76.219.82
Has the domain A record been pointed to this server? [Y/n]: y

--- Step 3: Certificate ---
  [1] Cloudflare DNS  — recommended, no port 80 needed
  [2] Standalone HTTP — needs TCP 80 open on cloud firewall
Select certificate method [1]: 1
Enter Cloudflare API Token: ****

--- Step 4: ACME email ---
ACME email for Let's Encrypt [admin@jp.example.com]:

--- Configuration summary ---
  Domain:       jp.example.com
  Certificate:  Cloudflare DNS
  Action:       install stack

Proceed? [Y/n]: y
```

### 部署前检查（推荐先跑）

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --check-only
```

也可在交互中输入域名后加 `--check-only`，或预填 `--domain your.domain.com --check-only`。

检查项包括：root 权限、系统/架构、内存磁盘、curl/wget、域名 A 记录是否指向本机、端口占用、证书模式、sing-box 是否可下载。

**防呆设计**（交互模式）：

| 环节 | 机制 |
|------|------|
| 域名 | 格式校验、常见后缀拼写提示（.con→.com）、安装前二次输入确认 |
| IP | 显示公网 IP 并要求用户确认 |
| DNS | 自动比对 A 记录；检测 Cloudflare 橙色云并提示改灰色云朵 |
| 证书 | CF Token 在线验证 + Zone 检查；Standalone 模式检测 80 端口，不通则引导改 CF |
| 重装 | 检测已有安装，覆盖前需确认 |
| 失败 | 安装出错时输出常见原因与回滚命令 |

### 非交互式安装（脚本/CI 用）

**Standalone**（需放行 **80/tcp**）：

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --domain your.domain.com \
  --email admin@your.domain.com \
  -y
```

**Cloudflare DNS**（推荐，无需 80 端口）：

```bash
apt-get update && apt-get install -y curl wget ca-certificates && \
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --domain your.domain.com \
  --email admin@your.domain.com \
  --cf-token YOUR_CLOUDFLARE_API_TOKEN \
  -y
```

> Vultr 等云厂商默认可能只开 22 端口；Standalone 模式需在防火墙放行 80/443/8443 等。

### 克隆仓库后安装

```bash
apt-get update && apt-get install -y git curl wget ca-certificates && \
git clone https://github.com/CNLiuBei/stable-proxy-stack.git && \
cd stable-proxy-stack && \
chmod +x install.sh && \
bash install.sh
```

## 安装参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `--domain` | ❌ | 域名（省略则交互输入） |
| `--email` | ❌ | ACME 邮箱，默认 `admin@域名` |
| `--cf-token` | ❌ | Cloudflare API Token（跳过 CF 交互询问） |
| `--check-only` | ❌ | 仅运行环境检查，不安装 |
| `--skip-check` | ❌ | 跳过预检（不推荐） |
| `-y, --yes` | ❌ | 非交互模式：跳过 DNS/CF 询问，警告时自动继续 |
| `--reality-dest` | ❌ | Reality 伪装目标，默认 `dl.google.com` |
| `--hy2-port-end` | ❌ | UDP 端口跳跃上限，默认 `450` |
| `--sing-box-version` | ❌ | sing-box 版本，默认 `1.13.14` |

## 安装完成后

配置文件与订阅链接保存在：

```
/etc/stable-proxy-stack/subscribe.txt       # 节点链接
/etc/stable-proxy-stack/credentials.txt   # 密钥信息
/etc/stable-proxy-stack/clash-meta.yaml   # Clash Meta 配置片段
```

### 客户端建议

**Clash Meta** 策略组示例：

```yaml
proxy-groups:
  - name: "稳定优先"
    type: fallback
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - "reality-main"
      - "hy2-backup"
```

- 主力：**Reality** 节点
- 备用：**hy2** 节点
- 规则：国内直连，其余走「稳定优先」

## 包含的优化

- [x] 交互式引导（域名 / DNS 确认 / CF 证书）
- [x] 极简镜像自动安装 curl/wget
- [x] VLESS + Reality + Vision TCP 443 主力
- [x] hy2 UDP 443 + Salamander obfs
- [x] UDP 端口跳跃 443-450
- [x] Nginx 8443 伪装站
- [x] BBR 拥塞控制
- [x] UDP 缓冲区 64MB
- [x] DNS 独立缓存
- [x] 证书自动续期（acme.sh）
- [x] sing-box 健康检查（每 5 分钟）
- [x] UFW 防火墙

## 卸载

```bash
bash uninstall.sh
```

## 免责声明

本项目仅供学习与技术研究，请遵守当地法律法规，在授权范围内使用。

## License

MIT
