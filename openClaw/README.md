# OpenClaw

基于 [OpenClaw](https://github.com/openclaw/openclaw)（当前版本 **2026.3.2**）的个人 AI 助手服务，通过 Gateway（WebSocket）运行，支持 WhatsApp、Telegram、Slack、Discord 等多渠道接入。

**访问方式**：服务本身仅监听本地回环地址，必须通过 **SSH 隧道** 安全访问网页控制台。

## 依赖

| 组件 | 版本要求 | 安装方式 |
|------|---------|----------|
| Node.js | **≥ 22**（LTS 不够，必须 22+） | `base/03_nodejs.sh --v22` |

---

## 安装

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
# 安装 OpenClaw 服务
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
/root/openclaw-manage.sh upgrade
# 或
sudo bash install_openclaw.sh upgrade
```

---

## 卸载

```bash
sudo bash install_openclaw.sh remove
```

交互式确认后，依次：停止 Gateway → 卸载系统服务 → 卸载 npm 包 → 删除管理脚本 → 可选删除配置目录。

---

## 日常管理

管理脚本位于 `/root/openclaw-manage.sh`：

| 命令 | 说明 |
|------|------|
| `start` | 启动 Gateway 服务 |
| `stop` | 停止 Gateway 服务 |
| `restart` | 重启 Gateway 服务 |
| `status` | 查看服务状态 |
| `health` | WebSocket 健康检查 |
| `logs` | 实时查看 Gateway 日志 |
| `onboard` | 运行初始化向导（首次安装后执行）|
| `profile [value]` | 查看或设置 `tools.profile` |
| `upgrade` | 升级到最新版本 |
| `version` | 查看 OpenClaw 版本 |
| `config <args>` | 透传 `openclaw config` 命令 |
| `test` | 检查环境 + 访问方式 |

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

| 路径 | 说明 |
|------|------|
| `~/.openclaw/` | OpenClaw 配置目录（config、workspace、sessions）|
| `~/.openclaw/openclaw.json` | 主配置文件（AI 模型、渠道、网关令牌等）|
| `/root/openclaw-manage.sh` | 管理脚本 |
| Gateway 端口 | `18789`（WebSocket，仅本机回环）|

---

## 注意事项

- **端口**：OpenClaw Gateway 默认仅监听 `127.0.0.1:18789`，必须通过 SSH 隧道才能从浏览器访问。
- **服务管理**：OpenClaw 通过自带的 `openclaw gateway` 管理系统服务，使用管理脚本即可，**不要直接操作 systemctl**。
- **exec 安全**：`tools.profile = full` 开启后 AI 可执行任意 shell 命令，仅在受控服务器上使用。
