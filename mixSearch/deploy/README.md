# hybrid-search - 混合搜索服务部署指南

一个集成的搜索解决方案，结合了本地元搜索引擎 **SearXNG** 和 AI 搜索 **Tavily**，并通过一个统一的 **FastAPI Adapter** 对外提供服务。整个服务通过 Docker Compose 运行，易于部署和管理。

## 架构

| 组件 | 端口 | 说明 |
|------|------|------|
| Adapter | `18000` | FastAPI 搜索网关，作为 Agent 的统一调用入口。|
| SearXNG | `18999` | 本地元搜索引擎，可配置多种搜索引擎。|
| Redis | 内部 | SearXNG 的缓存后端，加速重复查询。|

---

## 搜索模式

服务支持两种搜索模式，通过安装时的 `--mode` 参数控制：

### 1. GFW 模式 (`--mode gfw`) - 默认

**描述**：仅使用在 GFW 环境下稳定可用的搜索引擎（如 Bing, Baidu, DuckDuckGo）以及自定义的技术和新闻源。

**优点**：
- 无需外网访问能力，部署简单
- 响应速度快，稳定性高
- 适合大陆服务器直接部署

**包含的引擎**：
- 通用搜索：Bing, Baidu, DuckDuckGo
- 技术社区：GitHub, StackExchange, 掘金, CSDN
- 财经新闻：东方财富, 财联社, 36氪
- 国际资讯：The Economist, Foreign Affairs

### 2. 全球模式 (`--mode global`)

**描述**：在 GFW 模式的基础上，额外启用 Google, Wikipedia, WolframAlpha 等强大的国际搜索引擎，并集成高质量的国际新闻 RSS 源。

**优点**：
- 搜索结果质量更高，信息源更广泛
- 获取最新的国际科技和商业资讯
- 适合需要全球视野的应用场景

**额外包含的引擎**：
- 国际搜索：Google, Wikipedia, WolframAlpha
- 国际新闻：Reuters, BBC News, TechCrunch, Ars Technica, Hacker News

**要求**：
- ⚠️ **服务器本身必须具备外网访问能力**（例如，通过 Clash 等代理工具）
- 代理需配置为透明代理或全局模式，确保 Docker 容器内的请求可以访问外网

**关于 Docker 镜像加速**：
- 安装脚本已自动配置国内 Docker 镜像源（腾讯云、中科大等）
- 拉取 Docker 镜像（如 `searxng/searxng`）时会优先使用国内镜像，**不消耗代理流量**
- 只有搜索请求访问 Google 等国际引擎时才会使用代理

---

## 安装与部署

### 前置依赖

- Docker & Docker Compose
- `sudo` 权限
- （仅 global 模式）服务器能访问外网

### Step 1：安装基础环境

```bash
sudo bash base/setup_all.sh --with-docker
```

### Step 2：运行安装脚本

根据您的网络环境，选择一种模式进行安装。

#### GFW 模式（默认，推荐大陆服务器）

```bash
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh \
  --searxng-port 18999 --adapter-port 18000
```

#### 全球模式（服务器需能访问外网）

```bash
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh \
  --mode global \
  --searxng-port 18999 --adapter-port 18000
```

#### 安装参数说明

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--mode` | 搜索模式：`gfw` 或 `global` | `gfw` |
| `--searxng-port` | SearXNG 对外端口 | `18999` |
| `--adapter-port` | Adapter 对外端口 | `18000` |
| `--allow-cidr` | 防火墙放行网段 | 自动检测 VPC |
| `--install-dir` | 安装目录 | `/root/hybrid-search` |
| `--force` | 覆盖已有文件 | 否 |

### Step 3：配置 Tavily API Key

```bash
vim /root/hybrid-search/deploy/.env
```

找到 `TAVILY_API_KEY=` 这行，填入你的 Key：

```
TAVILY_API_KEY=tvly-xxxx
```

保存后重启服务使配置生效：

```bash
cd /root/hybrid-search/deploy
docker compose up -d --build
```

> 如果暂时没有 Tavily Key，可以跳过这步。系统会以 SearXNG-only 模式运行，不会报错。

### Step 4：验证安装

```bash
# 4a. 检查三个容器是否都是 Up (healthy)
docker ps --format "table {{.Names}}\t{{.Status}}"

# 4b. 健康检查
curl -fsS "http://127.0.0.1:18000/healthz"

# 4c. 搜索测试
curl -fsS -X POST "http://127.0.0.1:18000/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"python fastapi tutorial","max_results":5}'
```

**至此安装完成。** 服务已可被同 VPC 内的 OpenClaw / CoPaw 调用。

---

## 切换搜索模式

如果您想在已部署的服务上切换搜索模式（例如，从 `gfw` 切换到 `global`），只需**重新运行安装脚本**并指定新的模式即可。脚本会自动覆盖配置文件并重启服务。

```bash
# 切换到 global 模式
sudo bash mixSearch/deploy/scripts/install_searxng_tavily.sh --mode global --force
```

---

## 服务器上的最终文件结构

```text
/root/hybrid-search/               ← 运行时目录（INSTALL_DIR）
  deploy/
    .env                            ← 脚本自动生成（含 secret）
    docker-compose.yml              ← 从源文件复制
  adapter/
    app.py                          ← 从源文件复制
    requirements.txt
    Dockerfile
  searxng/
    settings.yml                    ← 脚本自动生成（根据模式）
    limiter.toml                    ← 从源文件复制
    engines/
      juejin.py                     ← 自定义引擎
      csdn.py                       ← 自定义引擎
      reuters.py                    ← 国际新闻引擎（global 模式）
      bbc.py                        ← 国际新闻引擎（global 模式）
      ...
```

---

## 配置参考

### Step 5（可选）：调整配置

配置文件位于 `/root/hybrid-search/deploy/.env`，以下是最常调整的项：

| 配置项 | 默认值 | 何时改 |
|---|---|---|
| `TAVILY_API_KEY` | 空 | 必填，否则无 Tavily 兜底 |
| `ALLOW_CIDR` | 自动检测 | VPC 网段不对时手动指定 |
| `LOCAL_MIN_RESULTS` | `3` | 想更积极用 Tavily 可改 `4-5` |
| `REQUEST_TIMEOUT_MS` | `8000` | 网络慢时可升到 `10000-12000` |
| `SEARXNG_PORT` | `18999` | 端口冲突时再改 |
| `ADAPTER_PORT` | `18000` | 端口冲突时再改 |

修改后执行：

```bash
cd /root/hybrid-search/deploy
docker compose up -d --build
```

### 端口与网络

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SEARXNG_PORT` | `18999` | SearXNG 对外端口 |
| `ADAPTER_PORT` | `18000` | Adapter 对外端口 |
| `ALLOW_CIDR` | 自动检测 | 防火墙放行网段 |

### 兜底策略

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ENABLE_TAVILY` | `true` | 是否启用 Tavily 兜底 |
| `LOCAL_MIN_RESULTS` | `3` | 本地结果少于此值触发 Tavily |
| `TAVILY_API_KEY` | 空 | Tavily 密钥 |

### 超时与重试

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REQUEST_TIMEOUT_MS` | `8000` | 总请求超时 |
| `ENGINE_TIMEOUT_MS` | `2500` | 单引擎连接超时 |
| `RETRY_COUNT` | `1` | 失败重试次数 |
| `RETRY_BACKOFF_MS` | `250` | 重试退避起始毫秒 |

### 缓存与限流

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CACHE_TTL_SEC` | `1800` | 成功结果缓存 30 分钟 |
| `NEGATIVE_CACHE_TTL_SEC` | `120` | 空结果缓存 2 分钟 |
| `RATE_LIMIT_RPM` | `30` | 每分钟请求限制 |
| `BURST` | `10` | 瞬时突发额度 |

### 排序权重

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WEIGHT_EN_DEFAULT / ZH` | `0.65 / 0.35` | 默认查询 |
| `WEIGHT_EN_TECH / ZH` | `0.75 / 0.25` | 技术查询 |
| `WEIGHT_EN_LOCAL / ZH` | `0.40 / 0.60` | 本地资讯类查询 |

---

## 日常运维

### 查看日志

```bash
# Adapter 实时日志
docker logs -f hybrid-adapter

# SearXNG 日志
docker logs --tail 50 hybrid-searxng
```

日志示例：

```
2026-03-03T10:30:15 INFO [adapter] search query='python fastapi' max_results=5 client=10.0.1.20
2026-03-03T10:30:16 INFO [adapter] searxng_ok count=8 query='python fastapi'
2026-03-03T10:30:16 INFO [adapter] search_done query='python fastapi' local=8 tavily=0 ranked=5
```

### 常用命令

| 操作 | 命令 |
|---|---|
| 查看状态 | `docker ps --format "table {{.Names}}\t{{.Status}}"` |
| 重启服务 | `cd /root/hybrid-search/deploy && docker compose restart` |
| 停止服务 | `cd /root/hybrid-search/deploy && docker compose down` |
| 查看日志 | `docker logs -f hybrid-adapter` |

### 升级

```bash
# 1. 重新上传源文件
scp -r mixSearch/deploy root@<server-ip>:/root/hybrid-search-src/

# 2. 强制覆盖并重启
ssh root@<server-ip>
bash /root/hybrid-search-src/scripts/install_searxng_tavily.sh --force
cd /root/hybrid-search/deploy
docker compose up -d --build
```

### 卸载

```bash
cd /root/hybrid-search/deploy
docker compose down
rm -rf /root/hybrid-search
```
