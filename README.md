# Clawbot

个人 AI 助手服务集合，运行在腾讯云 OpenCloudOS 8（2C4G）上，所有安装脚本针对 GFW 环境优化，使用国内镜像源。

## 项目结构

```
clawbot/
├── base/                         ← 基础环境安装脚本（所有服务的共同前置）
│   ├── 01_system_base.sh         # 系统包 + EPEL + 全局镜像配置
│   ├── 02_python312.sh           # Python 3.12 + pip（阿里云镜像）
│   ├── 03_nodejs.sh              # Node.js via nvm（npmmirror）
│   ├── 04_docker.sh              # Docker CE + Compose（腾讯云镜像）
│   ├── 05_playwright.sh          # Playwright 1.56.0 + Chromium（npmmirror）
│   ├── 06_clash.sh               # Mihomo (Clash) 代理客户端（解决地区限制）
│   ├── check_all.sh              # 一键检查所有组件安装状态
│   └── setup_all.sh              # 组合安装入口（按需选择组件）
│
├── coPaw/                        ← CoPaw AI Agent 服务
│   ├── README.md                 # 部署与使用文档
│   └── install_copaw.sh          # 安装 / 升级 / 卸载
│
├── openClaw/                     ← OpenClaw AI 助手服务
│   ├── README.md                 # 部署与使用文档
│   └── install_openclaw.sh       # 安装 / 升级 / 卸载
│
└── mixSearch/                    ← 混合搜索服务（供 coPaw / OpenClaw 调用）
    ├── deploy/
    │   ├── README.md             ← mixSearch 详细部署文档
    │   ├── scripts/
    │   │   └── install_searxng_tavily.sh  # 一键部署脚本
    │   ├── adapter/              # FastAPI 搜索网关（源码）
    │   ├── searxng/              # SearXNG 配置 + 自定义引擎
    │   └── compose/              # docker-compose.yml
    └── skills/
        └── hybrid-search/        # OpenClaw / CoPaw skill 定义
```

---

## 各服务说明

### base — 基础环境

所有服务的共同前置，按需组合安装。每个脚本均支持 `install`（幂等）/ `remove` 两个模式。

| 脚本 | 作用 | remove 支持 |
|------|------|:-----------:|
| `01_system_base.sh` | 系统包、EPEL、全局镜像变量 | ✅ |
| `02_python312.sh` | Python 3.12 + pip 阿里云镜像 | ✅ |
| `03_nodejs.sh` | nvm + Node.js LTS 或 v22 | ✅ |
| `04_docker.sh` | Docker CE + daemon 镜像加速 | ✅ |
| `05_playwright.sh` | Playwright 1.56.0 + Chromium | ✅ |
| `06_clash.sh` | Mihomo (Clash) 代理客户端（解决 Claude/OpenAI 地区限制） | ✅ |
| `check_all.sh` | 检查所有组件状态（只读，无需 root）| — |

镜像源策略：

| 类型 | 镜像 |
|------|------|
| pip / uv | mirrors.aliyun.com/pypi |
| npm / nvm | npmmirror.com（淘宝） |
| EPEL / dnf | mirrors.aliyun.com/epel |
| Docker CE repo | mirrors.cloud.tencent.com |
| Docker daemon | 腾讯云 / 中科大加速器 |
| Playwright 浏览器 | cdn.npmmirror.com |
| Mihomo 二进制 | gh.llkk.cc（GitHub 镜像） |

---

### 06_clash.sh — Mihomo (Clash) 代理

Mihomo (Clash Meta) 代理客户端，解决腾讯云等中国大陆 IP 访问 OpenRouter / Claude / OpenAI 被 403 的问题。通过订阅链接（Clash 格式）导入节点，以 systemd 服务常驻运行。

HTTP 代理端口：`7890`  ·  SOCKS5：`7891`  ·  REST API：`9090`（仅本机）

```bash
# 安装（幂等）
sudo bash base/06_clash.sh

# 导入/更新订阅
sudo bash base/06_clash.sh update-sub 'https://your-sub?clash=1'

# 给 OpenClaw 注入代理环境变量并重启
sudo bash base/06_clash.sh inject-openclaw

# 卸载
sudo bash base/06_clash.sh remove
```

#### 查看当前节点

```bash
curl -s http://127.0.0.1:9090/proxies | python3 -c "
import json,sys
data = json.load(sys.stdin)
for name, info in data['proxies'].items():
    if info.get('type') == 'Selector':
        print(f'{name}: {info.get(\"now\", \"未知\")}')
"
```

#### 切换节点（API）

```bash
# 切换主代理组 ✈️Proxy 到指定节点
curl -X PUT 'http://127.0.0.1:9090/proxies/%E2%9C%88%EF%B8%8FProxy' \
  -H 'Content-Type: application/json' \
  -d '{"name": "节点名称"}'

# 常用节点示例（支持 OpenAI/Claude）
# B09.新加坡-Netflix丨Disney+丨OpenAI   → 新加坡
# B13.美国- Netflix丨OpenAI             → 美国
# B21.日本 -Netflix丨OpenAI             → 日本
# B25.马来西亚 OpenAI                   → 马来西亚
```

#### Web 控制面板（可视化切换节点）

在本地 Mac 建立 SSH 端口转发：

```bash
ssh -i tencent.pem -L 9090:127.0.0.1:9090 -N root@YOUR_SERVER_IP
```

然后浏览器打开 [https://metacubexd.pages.dev](https://metacubexd.pages.dev)，填入 `http://127.0.0.1:9090` 即可图形化查看和切换节点。

#### 验证代理出口 IP

```bash
curl -x http://127.0.0.1:7890 -s https://api.ip.sb/geoip | python3 -m json.tool
```

---

### coPaw — AI Agent 服务

基于 [CoPaw](https://github.com/copaw/copaw) + [AgentScope](https://github.com/modelscope/agentscope)，通过 systemd 守护运行，默认端口 `7077`。

依赖：Python 3.12 · Node.js LTS · Playwright 1.56.0

```bash
# 安装
sudo bash base/setup_all.sh --with-python --with-playwright
sudo bash coPaw/install_copaw.sh

# 管理
/root/copaw-manage.sh {start|stop|restart|status|logs|init|venv|test|upgrade}
```

详细文档：[coPaw/README.md](coPaw/README.md)

---

### OpenClaw — AI 助手服务

基于 [OpenClaw](https://github.com/openclaw/openclaw)（2026.3.2），通过 Gateway（WebSocket `18789`）运行，支持 Telegram、WhatsApp、Slack 等多渠道接入。

依赖：Node.js 22+

```bash
# 安装（无代理）
sudo bash base/setup_all.sh --node-v22
sudo bash openClaw/install_openclaw.sh

# 安装（含 Clash 代理，解决 Claude/OpenRouter 地区限制）
sudo bash base/setup_all.sh --node-v22 --with-clash
sudo bash openClaw/install_openclaw.sh
sudo bash base/06_clash.sh update-sub '订阅链接'
sudo bash base/06_clash.sh inject-openclaw

# 首次初始化（配置 AI provider、渠道等）
/root/openclaw-manage.sh onboard

# 管理
/root/openclaw-manage.sh {start|stop|restart|status|health|logs|onboard|profile|upgrade}
```

> **注意**：2026.3.2 起 `tools.profile` 默认为 `messaging`（不含 exec/shell 工具）。安装脚本已自动设置为 `full`，如需修改：`/root/openclaw-manage.sh profile [full|coding|messaging|minimal]`

详细文档：[openClaw/README.md](openClaw/README.md)

---

### mixSearch — 混合搜索服务

SearXNG（本地元搜索）+ Tavily（兜底）+ FastAPI Adapter，通过 Docker Compose 运行。

| 组件 | 端口 | 说明 |
|------|------|------|
| Adapter | `18000` | FastAPI 搜索网关（Agent 调用入口） |
| SearXNG | `18999` | 本地元搜索引擎 |
| Redis | 内部 | SearXNG 缓存后端 |

依赖：Docker CE

```bash
# 安装
sudo bash base/setup_all.sh --with-docker
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh \
  --searxng-port 18999 --adapter-port 18000

# 配置 Tavily Key（可选，用于搜索结果兜底）
vim /root/hybrid-search/deploy/.env   # 填写 TAVILY_API_KEY=tvly-xxx

# 验证
curl -fsS http://127.0.0.1:18000/healthz
curl -X POST http://127.0.0.1:18000/search \
  -H "Content-Type: application/json" \
  -d '{"query":"今日科技新闻","max_results":5}'
```

详细文档：[mixSearch/deploy/README.md](mixSearch/deploy/README.md)

---

## 快速开始（典型场景）

### 场景 A：全新服务器安装 CoPaw + mixSearch

```bash
# 1. 基础环境
sudo bash base/setup_all.sh --with-python --with-playwright --with-docker

# 2. CoPaw
sudo bash coPaw/install_copaw.sh
/root/copaw-manage.sh init
/root/copaw-manage.sh start

# 3. mixSearch
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh

# 4. 检查
bash base/check_all.sh --venv /root/copaw-venv
```

### 场景 B：全新服务器安装 OpenClaw + mixSearch

```bash
# 1. 基础环境（含 Clash 代理解决地区限制）
sudo bash base/setup_all.sh --node-v22 --with-docker --with-clash

# 2. OpenClaw
sudo bash openClaw/install_openclaw.sh
/root/openclaw-manage.sh onboard

# 3. 配置 Clash 订阅并注入代理到 OpenClaw
sudo bash base/06_clash.sh update-sub '订阅链接'
sudo bash base/06_clash.sh inject-openclaw

# 4. mixSearch
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh

# 5. 检查
bash base/check_all.sh
```

### 场景 C：只部署 mixSearch

```bash
sudo bash base/setup_all.sh --with-docker
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh
bash base/check_all.sh
```

---

## 检查与诊断

```bash
# 检查所有基础组件
bash base/check_all.sh

# 检查 CoPaw venv 内部（包含 copaw/agentscope/playwright 包状态）
bash base/check_all.sh --venv /root/copaw-venv

# 查看各服务状态
systemctl status copaw
systemctl status openclaw
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## 卸载

### 应用服务

```bash
# CoPaw（含 venv、systemd 服务、管理脚本）
sudo bash coPaw/install_copaw.sh remove

# OpenClaw（含 npm 全局包、systemd 服务、管理脚本）
sudo bash openClaw/install_openclaw.sh remove

# mixSearch（停止并删除容器、运行时目录）
cd /root/hybrid-search/deploy && docker compose down
rm -rf /root/hybrid-search /root/hybrid-search-src
```

### 基础组件（按需单独删除）

每个 base 脚本均支持 `remove` 子命令，**只删除对应组件**，不影响其他部分。

```bash
# Playwright 浏览器缓存 + Python 包
sudo bash base/05_playwright.sh remove
# 如果装在 venv 里：
sudo bash base/05_playwright.sh remove --venv /root/copaw-venv

# Mihomo (Clash) 代理客户端
sudo bash base/06_clash.sh remove

# Docker CE（停止服务 + 卸载包 + 删除 repo）
sudo bash base/04_docker.sh remove

# Node.js + nvm（删除 ~/.nvm 及软链接）
sudo bash base/03_nodejs.sh remove

# Python 3.12
sudo bash base/02_python312.sh remove

# 系统镜像配置（删除 EPEL + /etc/profile.d/clawbot_mirrors.sh + pip.conf）
sudo bash base/01_system_base.sh remove
```

> **注意**：`01_system_base.sh remove` 不会删除通过 dnf 安装的系统基础包（gcc / git / curl 等），如需删除请手动执行 `dnf remove`。

---

## 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | OpenCloudOS 8 / CentOS 8 / RHEL 8 |
| 配置 | 2C4G 及以上 |
| 网络 | 支持 GFW 环境（全程国内镜像） |
| 权限 | root |
