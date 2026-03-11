# OpenClaw

基于 [OpenClaw](https://github.com/openclaw/openclaw)（当前版本 **2026.3.2**）的个人 AI 助手服务，通过 Gateway（WebSocket）运行，支持 WhatsApp、Telegram、Slack、Discord 等多渠道接入。

**访问方式**：服务本身仅监听本地回环地址，必须通过 **SSH 隧道** 安全访问网页控制台。

## 安装方式对比

| | npm 安装（原生） | Docker 安装 |
|------|:---:|:---:|
| 依赖 | Node.js ≥ 22 | Docker CE + Compose v2 |
| 服务管理 | systemd | Docker Compose |
| 适合场景 | 直接部署、开发调试 | 隔离环境、一键部署 |
| 安装脚本 | `install_openclaw.sh` | `install_openclaw_docker.sh` |

---

## 方式 A：npm 安装（原生）

### 依赖

| 组件 | 版本要求 | 安装方式 |
|------|---------|----------|
| Node.js | **≥ 22**（LTS 不够，必须 22+） | `base/03_nodejs.sh --v22` |

### Step 1：安装基础环境

```bash
sudo bash ../base/01_system_base.sh
sudo bash ../base/03_nodejs.sh --v22
```

或使用一键脚本：

```bash
sudo bash ../base/setup_all.sh --node-v22
```

### Step 2：安装 OpenClaw

```bash
sudo bash install_openclaw.sh
```

脚本自动完成：
1. 检查 Node.js ≥ 22
2. 安装 `openclaw@latest`（npm 全局，npmmirror 镜像）
3. **开启 `tools.profile = full`**（含 exec/shell 工具）
4. 通过 `openclaw gateway install` 注册系统服务
5. 生成管理脚本 `/root/openclaw-manage.sh`

### Step 3：运行初始化向导

```bash
/root/openclaw-manage.sh onboard
```

向导引导完成：AI 模型提供商配置、消息渠道接入（Telegram/WhatsApp 等）、Workspace 路径设置。

### Step 4：启动服务并验证

```bash
/root/openclaw-manage.sh start
/root/openclaw-manage.sh test     # 显示环境信息 + 访问方式
/root/openclaw-manage.sh health   # Gateway WebSocket 健康检查
```

---

## 方式 B：Docker 安装

使用官方容器镜像 `ghcr.io/openclaw/openclaw:latest`（基于 `node:22-bookworm`），通过 Docker Compose 管理，配置持久化到宿主机。

### 依赖

| 组件 | 版本要求 | 安装方式 |
|------|---------|----------|
| Docker CE | ≥ 20.10 | `base/04_docker.sh` |
| Docker Compose | v2 | Docker CE 已包含 |
| 内存 | ≥ 2GB | — |

### Step 1：安装 Docker

```bash
sudo bash ../base/04_docker.sh
```

> Docker 方式不需要运行 `01_system_base.sh`，应用运行在容器内，宿主机只需要 Docker CE + Compose。

### Step 2：安装 OpenClaw Docker

```bash
# 标准安装（直接拉取 ghcr.io 镜像）
sudo bash install_openclaw_docker.sh

# GFW 环境（通过 Clash 代理拉取镜像）
sudo bash install_openclaw_docker.sh --with-proxy
```

脚本自动完成：
1. 检查 Docker + Compose
2. 如指定 `--with-proxy`，临时配置 Docker daemon 走 Clash 代理拉取 ghcr.io 镜像
3. 生成 `.env` 配置文件
4. 拉取镜像并启动 Gateway 容器
5. **设置 `tools.profile = full`**
6. 生成管理脚本 `/root/openclaw-manage.sh`

### Step 3：运行初始化向导

```bash
/root/openclaw-manage.sh onboard
```

### Step 4：验证

```bash
/root/openclaw-manage.sh status    # 查看容器状态
/root/openclaw-manage.sh health    # healthz + readyz
/root/openclaw-manage.sh test      # 完整环境信息
```

### Docker 版代理配置（Clash → AI Provider）

容器内访问 Claude/OpenRouter 等需要代理时，使用 `inject-proxy` 注入代理环境变量：

```bash
# 默认使用 host.docker.internal:7890（Clash 代理）
/root/openclaw-manage.sh inject-proxy

# 或指定自定义代理地址
/root/openclaw-manage.sh inject-proxy http://172.17.0.1:7890
```

> **注意**：`host.docker.internal` 在 Linux 上需要 Docker 20.10.0+ 且添加 `--add-host` 或使用宿主机网桥 IP（通常 `172.17.0.1`）。

### Docker 版文件位置

| 路径 | 说明 |
|------|------|
| `/root/openclaw-docker/` | Docker Compose 运行目录 |
| `/root/openclaw-docker/.env` | 环境变量配置 |
| `/root/openclaw-docker/docker-compose.yml` | Compose 文件 |
| `~/.openclaw/` | 配置目录（宿主机挂载到容器） |
| `/root/openclaw-manage.sh` | 管理脚本 |

---

## 网页访问 Control UI

> OpenClaw Gateway 默认仅监听 `127.0.0.1:18789`，**必须通过 SSH 隧道才能从外部浏览器安全访问**。

### 操作步骤

1.  **建立 SSH 隧道**
    在**您的本地电脑**上打开一个终端，运行以下命令。此命令会创建一个加密隧道，将您本地的 18789 端口转发到服务器的 18789 端口。
    ```bash
    ssh -L 18789:localhost:18789 -i /path/to/your/key.pem root@YOUR_SERVER_IP
    ```
    **保持此终端窗口不要关闭**，隧道将在其生命周期内保持连接。

2.  **浏览器访问**
    打开浏览器，访问以下地址：
    [http://localhost:18789](http://localhost:18789)

3.  **Token 认证**
    在打开的页面中，输入您的 Gateway 访问令牌。您可以在服务器的 `~/.openclaw/openclaw.json` 文件中找到它，路径为 `gateway.auth.token`。

---

## 关于 tools.profile（重要）

> **2026.3.2 Breaking Change**：onboard 流程默认将 `tools.profile` 设为 `messaging`，**不再默认开启 exec/shell/coding 工具**。

安装脚本已在 onboard 前写入 `tools.profile = full`，但如果手动 onboard 或 reset 后需要重新确认：

```bash
# 查看当前 profile
/root/openclaw-manage.sh profile

# 设置为 full（开启所有工具，含执行系统命令）
/root/openclaw-manage.sh profile full

# 可选值
# full      — 无限制（exec/shell/coding/file/memory 全开）
# coding    — 文件系统 + 运行时 + session + memory
# messaging — 仅消息和 session 工具（默认）
# minimal   — 仅基本 session 状态
```

修改 profile 后会自动重启 Gateway 使配置生效。

---

## 升级

```bash
# npm 安装方式
/root/openclaw-manage.sh upgrade
# 或
sudo bash install_openclaw.sh upgrade

# Docker 安装方式（拉取最新镜像并重建容器）
/root/openclaw-manage.sh upgrade
# 或
sudo bash install_openclaw_docker.sh upgrade
```

---

## 卸载

```bash
# npm 安装方式
sudo bash install_openclaw.sh remove
# 交互式确认后：停止 Gateway → 卸载系统服务 → 卸载 npm 包 → 删除管理脚本 → 可选删除配置目录

# Docker 安装方式
sudo bash install_openclaw_docker.sh remove
# 交互式确认后：停止并删除容器 → 删除运行时目录 → 删除管理脚本 → 可选删除配置目录
```

---

## 日常管理

管理脚本位于 `/root/openclaw-manage.sh`，两种安装方式共享相同的命令接口：

| 命令 | 说明 | npm | Docker |
|------|------|:---:|:------:|
| `start` | 启动 Gateway | ✅ | ✅ |
| `stop` | 停止 Gateway | ✅ | ✅ |
| `restart` | 重启 Gateway | ✅ | ✅ |
| `status` | 查看服务状态 | ✅ | ✅ |
| `health` | 健康检查 | ✅ | ✅ |
| `logs` | 实时查看日志 | ✅ | ✅ |
| `onboard` | 运行初始化向导 | ✅ | ✅ |
| `profile [value]` | 查看/设置 `tools.profile` | ✅ | ✅ |
| `upgrade` | 升级到最新版本 | ✅ | ✅ |
| `version` | 查看版本 | ✅ | ✅ |
| `config <args>` | 透传 config 命令 | ✅ | ✅ |
| `test` | 检查环境 + 访问方式 | ✅ | ✅ |
| `dashboard` | 获取 Control UI 链接 | — | ✅ |
| `inject-proxy [url]` | 注入 AI 代理 | — | ✅ |

---

## 检查与诊断

```bash
# 环境自检（含访问方式说明）
/root/openclaw-manage.sh test

# Gateway 健康
/root/openclaw-manage.sh health

# 实时日志
/root/openclaw-manage.sh logs

# 检查基础组件
bash ../base/check_all.sh
```

---

## 文件位置

| 路径 | 说明 | npm | Docker |
|------|------|:---:|:------:|
| `~/.openclaw/` | 配置目录（config、workspace、sessions）| ✅ | ✅ |
| `~/.openclaw/openclaw.json` | 主配置文件 | ✅ | ✅ |
| `/root/openclaw-manage.sh` | 管理脚本 | ✅ | ✅ |
| `/root/openclaw-docker/` | Docker Compose 运行目录 | — | ✅ |
| Gateway 端口 | `18789`（WebSocket，仅本机回环）| ✅ | ✅ |

---

## 注意事项

- **端口**：OpenClaw Gateway 默认仅监听 `127.0.0.1:18789`，必须通过 SSH 隧道才能从浏览器访问。
- **服务管理（npm）**：通过自带的 `openclaw gateway` 管理系统服务，使用管理脚本即可，**不要直接操作 systemctl**。
- **服务管理（Docker）**：通过 Docker Compose 管理，使用管理脚本即可，**不要直接操作 docker 命令**。
- **exec 安全**：`tools.profile = full` 开启后 AI 可执行任意 shell 命令，仅在受控服务器上使用。
- **Docker 内存**：容器默认不设内存限制，如需限制可在 `docker-compose.yml` 中添加 `mem_limit`。
