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

> **极简镜像说明**：部分 VPS 出厂未预装 `curl`。脚本会在预检前通过 `apt` 自动安装 `curl` / `wget`（需 root）。若系统既无 curl 又无 wget 且无法使用 apt，请先手动安装后再运行，或改用下方「克隆仓库」方式。

## 一键安装

### 部署前检查（推荐先跑）

在**你的电脑**上执行（管道里的 `curl` 是本地客户端，用于把脚本下载到 VPS 执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --domain your.domain.com \
  --check-only
```

检查项包括：root 权限、系统/架构、内存磁盘、**curl/wget 可用性**、**域名 A 记录是否指向本机**、端口占用、证书模式提示、sing-box 是否可下载。

### 方式一：Standalone 模式（域名已指向 VPS，自动申请证书）

```bash
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --domain your.domain.com \
  --email admin@your.domain.com
```

> **注意**：需在云厂商防火墙放行 **80/tcp**（证书验证）及 443/8443 等端口。Vultr 默认可能只开 22。

### 方式二：Cloudflare DNS 验证（推荐，无需开放 80 端口）

```bash
curl -fsSL https://raw.githubusercontent.com/CNLiuBei/stable-proxy-stack/main/install.sh | bash -s -- \
  --domain your.domain.com \
  --email admin@your.domain.com \
  --cf-token YOUR_CLOUDFLARE_API_TOKEN
```

### 方式三：克隆仓库后安装（VPS 上无 curl 时推荐）

```bash
apt-get update && apt-get install -y git
git clone https://github.com/CNLiuBei/stable-proxy-stack.git
cd stable-proxy-stack
chmod +x install.sh
bash install.sh --domain your.domain.com --email admin@your.domain.com
```

脚本会自动检测并安装缺失的 `curl` / `wget`，无需在 VPS 上预先安装 curl。

## 安装参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `--domain` | ✅ | 你的域名 |
| `--email` | ❌ | ACME 邮箱，默认 `admin@域名` |
| `--cf-token` | ❌ | Cloudflare API Token（DNS 验证，无需 80 端口） |
| `--check-only` | ❌ | 仅运行环境检查，不安装 |
| `--skip-check` | ❌ | 跳过预检（不推荐） |
| `-y, --yes` | ❌ | 有警告时自动继续 |
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

- [x] 部署前环境检查（DNS/端口/系统/curl-wget）
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
