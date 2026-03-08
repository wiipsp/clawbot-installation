# Hybrid Search 部署指南（OpenCloudOS 8）

## 概览

| 组件 | 端口 | 说明 |
|---|---|---|
| SearXNG | `18999` | 本地元搜索引擎 |
| Adapter | `18000` | FastAPI 网关（Agent 调用入口） |
| Redis | 内部 | SearXNG 缓存后端 |

网络策略：仅同 VPC 网段可访问。

## 源码目录结构

```text
deploy/
  scripts/
    install_searxng_tavily.sh    # 一键安装脚本
  adapter/
    app.py                       # Adapter 源码（FastAPI）
    requirements.txt             # Python 依赖
    Dockerfile                   # Adapter 容器构建
  searxng/
    settings.yml                 # 本地开发配置（use_default_settings: true）
    settings.dev.yml             # 本地开发配置（同 settings.yml，显式备份）
    settings.prod.yml            # 生产环境配置（keep_only 过滤 GFW 屏蔽引擎）
    limiter.toml                 # SearXNG 限流/Bot 检测配置
    engines/
      juejin.py                  # 掘金自定义引擎
      csdn.py                    # CSDN 自定义引擎
  compose/
    docker-compose.yml           # 容器编排（含 healthcheck）
  .env.example                   # 环境变量参考模板
  README.md                      # 本文件
```

---

## 新安装（Step by Step）

### 前置条件

- 腾讯云 CVM（建议 2C4G 及以上）
- 系统：OpenCloudOS 8
- 权限：`root` 或可 `sudo`
- 网络：可访问 Docker Hub / GitHub

### Step 1：上传源文件到服务器

在**本地机器**执行：

```bash
scp -r mixSearch/deploy root@<server-ip>:/root/hybrid-search-src/
```

### Step 2：SSH 登录服务器，运行安装脚本

```bash
ssh root@<server-ip>

chmod +x /root/hybrid-search-src/scripts/install_searxng_tavily.sh

bash /root/hybrid-search-src/scripts/install_searxng_tavily.sh \
  --searxng-port 18999 \
  --adapter-port 18000
```

> 脚本会自动完成以下所有工作：
> 1. 安装 Docker 和 Docker Compose
> 2. 将 `adapter/`、`searxng/`、`docker-compose.yml` 复制到 `/root/hybrid-search/`
> 3. 生成 `/root/hybrid-search/deploy/.env`（含随机 INSTANCE_SECRET + 自动检测的 VPC CIDR）
> 4. 配置 firewalld 防火墙规则
> 5. 拉取镜像并启动 Redis → SearXNG → Adapter（按 healthcheck 顺序）

可选参数：

| 参数 | 说明 | 默认值 |
|---|---|---|
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
# 预期输出: {"ok":true}

# 4c. 搜索测试
curl -fsS -X POST "http://127.0.0.1:18000/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"python fastapi tutorial","max_results":5}'
# 预期输出: {"query":"...","results":[...],"meta":{...}}
```

**至此安装完成。** 服务已可被同 VPC 内的 OpenClaw / CoPaw 调用。

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
    settings.yml                    ← 从源文件复制
    limiter.toml                    ← 从源文件复制
    engines/
      juejin.py                     ← 自定义引擎
      csdn.py                       ← 自定义引擎

/root/hybrid-search-src/            ← SCP 上传的源文件（安装后可删除）
```

---

## 配置参考

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
rm -rf /root/hybrid-search /root/hybrid-search-src
```
