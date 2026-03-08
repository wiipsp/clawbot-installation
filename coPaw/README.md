# CoPaw

基于 [CoPaw](https://github.com/copaw/copaw) + [AgentScope](https://github.com/modelscope/agentscope) 的 AI Agent 服务，通过 systemd 守护运行，默认端口 `7077`。

**访问方式**：服务本身仅监听本地回环地址，必须通过 **SSH 隧道** 安全访问网页控制台。

## 依赖

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| Python | 3.12 | `base/02_python312.sh` |
| Node.js | LTS | `base/03_nodejs.sh --lts` |
| Playwright | 1.56.0 | `base/05_playwright.sh --venv /root/copaw-venv` |

---

## 安装

### Step 1：安装基础环境

```bash
sudo bash ../base/01_system_base.sh
sudo bash ../base/02_python312.sh
sudo bash ../base/03_nodejs.sh --lts
```

或使用一键组合脚本（在 `base/` 目录下执行）：

```bash
sudo bash ../base/setup_all.sh --with-python
```

### Step 2：安装 CoPaw

```bash
sudo bash install_copaw.sh
```

脚本会自动完成：
1. 创建 Python 3.12 虚拟环境 `/root/copaw-venv`
2. 安装 `agentscope`、`copaw`、`pysqlite3-binary`、`uv`、`playwright`
3. 修复 ChromaDB SQLite 兼容性补丁
4. 创建 systemd 服务（开机自启，**仅监听 127.0.0.1**）
5. 生成管理脚本 `/root/copaw-manage.sh`

### Step 3：安装 Playwright 浏览器

Playwright 浏览器需在 venv 创建后单独安装：

```bash
sudo bash ../base/05_playwright.sh --venv /root/copaw-venv
```

### Step 4：初始化并启动

```bash
/root/copaw-manage.sh init    # 首次配置向导
/root/copaw-manage.sh start   # 启动服务
/root/copaw-manage.sh logs    # 查看启动日志
```

---

## 网页访问 CoPaw UI

> CoPaw 服务默认仅监听 `127.0.0.1:7077`，**必须通过 SSH 隧道才能从外部浏览器安全访问**。

### 操作步骤

1.  **建立 SSH 隧道**
    在**您的本地电脑**上打开一个终端，运行以下命令。此命令会创建一个加密隧道，将您本地的 7077 端口转发到服务器的 7077 端口。
    ```bash
    ssh -L 7077:localhost:7077 -i /path/to/your/key.pem root@YOUR_SERVER_IP
    ```
    **保持此终端窗口不要关闭**，隧道将在其生命周期内保持连接。

2.  **浏览器访问**
    打开浏览器，访问以下地址：
    [http://localhost:7077](http://localhost:7077)

---

## 升级

```bash
sudo bash install_copaw.sh upgrade
```

会自动升级 `copaw`、`agentscope` 并重新应用 ChromaDB 补丁，升级完成后自动重启服务。

---

## 卸载

```bash
sudo bash install_copaw.sh remove
```

交互式确认后，依次删除：
- systemd 服务（停止 + 禁用）
- 虚拟环境 `/root/copaw-venv`
- 管理脚本 `/root/copaw-manage.sh`
- 可选：配置文件 `~/.copaw`、`~/.config/copaw`
- 可选：Playwright 浏览器缓存

---

## 日常管理

管理脚本位于 `/root/copaw-manage.sh`，用法：

```bash
/root/copaw-manage.sh <命令>
```

| 命令 | 说明 |
|------|------|
| `start` | 启动服务 |
| `stop` | 停止服务 |
| `restart` | 重启服务 |
| `status` | 查看 systemd 服务状态 |
| `logs` | 实时查看日志（`journalctl -f`） |
| `init` | 首次初始化 CoPaw 配置 |
| `venv` | 进入虚拟环境 Shell（自动加载 nvm） |
| `test` | 检查环境（Python / SQLite / Node / Playwright 版本） |
| `version` | 查看 CoPaw 版本 |
| `upgrade` | 升级 CoPaw + agentscope |
| `playwright-install` | 重新安装 / 更新 Playwright 浏览器 |

---

## 检查与诊断

```bash
# 检查基础组件 + venv 内部包状态
bash ../base/check_all.sh --venv /root/copaw-venv

# 快速环境自检
/root/copaw-manage.sh test

# 查看服务运行状态
systemctl status copaw

# 查看实时日志
/root/copaw-manage.sh logs
```

---

## 文件位置

| 路径 | 说明 |
|------|------|
| `/root/copaw-venv/` | Python 虚拟环境 |
| `/root/copaw-manage.sh` | 管理脚本 |
| `/etc/systemd/system/copaw.service` | systemd 服务文件 |
| `/root/.copaw/` | CoPaw 配置目录 |
| `/root/.cache/ms-playwright/` | Playwright 浏览器缓存 |
| `/root/.pip/pip.conf` | pip 阿里云镜像配置 |
