#!/usr/bin/env bash
set -euo pipefail

SEARXNG_PORT=18999
ADAPTER_PORT=18000
INSTALL_DIR="${HOME}/hybrid-search"
ALLOW_CIDR=""
FORCE_OVERWRITE=0
COMPOSE_VERSION="v2.23.0"
SEARCH_MODE="gfw" # 新增：默认为 GFW 模式
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/.."

log() { echo "[信息] $*"; }
warn() { echo "[警告] $*" >&2; }
err() { echo "[错误] $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install_searxng_tavily.sh [options]

Options:
  --mode <mode>             搜索模式: gfw (默认) 或 global (需要外网访问)
  --searxng-port <port>     SearXNG 对外端口 (默认: 18999)
  --adapter-port <port>     Adapter 对外端口 (默认: 18000)
  --install-dir <path>      安装根目录 (默认: $HOME/hybrid-search)
  --allow-cidr <cidr>       firewalld 放行网段 (默认: 自动识别)
  --compose-version <ver>   Docker Compose 独立版本 (默认: v2.23.0)
  --force                   覆盖已生成文件
  -h, --help                显示帮助
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) SEARCH_MODE="$2"; shift 2 ;;
      --searxng-port) SEARXNG_PORT="$2"; shift 2 ;;
      --adapter-port) ADAPTER_PORT="$2"; shift 2 ;;
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --allow-cidr) ALLOW_CIDR="$2"; shift 2 ;;
      --compose-version) COMPOSE_VERSION="$2"; shift 2 ;;
      --force) FORCE_OVERWRITE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "未知参数: $1"; usage; exit 1 ;;
    esac
  done
  if [[ "${SEARCH_MODE}" != "gfw" && "${SEARCH_MODE}" != "global" ]]; then
    err "无效的模式: ${SEARCH_MODE}。请使用 'gfw' 或 'global'。"
    exit 1
  fi
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 权限运行: sudo bash $0"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

copy_if_needed() {
  local src="$1"
  local target="$2"
  if [[ ! -f "${src}" ]]; then
    err "缺少源文件: ${src}"
    exit 1
  fi
  if [[ -f "${target}" && "${FORCE_OVERWRITE}" -eq 0 ]]; then
    log "保留已有文件: ${target}"
    return
  fi
  cp "${src}" "${target}"
  log "已复制: ${target}"
}

write_if_needed() {
  local target="$1"
  local content="$2"
  if [[ -f "${target}" && "${FORCE_OVERWRITE}" -eq 0 ]]; then
    log "保留已有文件: ${target}"
    return
  fi
  printf "%s" "${content}" >"${target}"
  log "已写入: ${target}"
}

detect_vpc_cidr() {
  local ip oct1 oct2
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"
  [[ -z "${ip}" ]] && { echo "10.0.0.0/8"; return; }
  IFS='.' read -r oct1 oct2 _ _ <<<"${ip}"
  if [[ "${oct1}" == "10" ]]; then
    echo "10.${oct2}.0.0/16"
  elif [[ "${oct1}" == "172" && "${oct2}" -ge 16 && "${oct2}" -le 31 ]]; then
    echo "172.${oct2}.0.0/16"
  elif [[ "${oct1}" == "192" && "${oct2}" == "168" ]]; then
    echo "192.168.0.0/16"
  else
    echo "10.0.0.0/8"
  fi
}

install_prerequisites() {
  local pkgs=(curl tar openssl python3)
  if has_cmd dnf; then
    dnf install -y "${pkgs[@]}"
  elif has_cmd yum; then
    yum install -y "${pkgs[@]}"
  else
    err "不支持的包管理器（仅支持 dnf/yum）"
    exit 1
  fi
}

install_docker() {
  if has_cmd docker; then
    log "检测到 Docker 已安装，跳过安装"
  else
    log "正在安装 Docker CE（腾讯云镜像）..."
    if has_cmd dnf; then
      dnf config-manager --add-repo https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo 2>/dev/null || dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
      sed -i 's|https://download.docker.com|https://mirrors.cloud.tencent.com/docker-ce|g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    else
      yum-config-manager --add-repo https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo 2>/dev/null || yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
      yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    fi
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DAEMON_EOF'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com", "https://dockerhub.timeweb.cloud", "https://docker.mirrors.ustc.edu.cn"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" }
}
DAEMON_EOF
  fi
  systemctl enable docker || true
  systemctl start docker || true
}

install_compose_if_needed() {
  if docker compose version >/dev/null 2>&1; then
    log "检测到 docker compose 可用"
    return
  fi
  local bin_dir="/usr/local/lib/docker/cli-plugins"
  local bin_path="${bin_dir}/docker-compose"
  [[ -x "${bin_path}" ]] && return
  mkdir -p "${bin_dir}"
  curl -fsSL "https://mirrors.cloud.tencent.com/docker-compose/${COMPOSE_VERSION}/docker-compose-linux-x86_64" -o "${bin_path}" 2>/dev/null || curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" -o "${bin_path}"
  chmod +x "${bin_path}"
}

prepare_files() {
  mkdir -p "${INSTALL_DIR}/deploy" "${INSTALL_DIR}/searxng/engines" "${INSTALL_DIR}/adapter"

  local secret
  secret="$(openssl rand -hex 32)"

  # 根据模式构建引擎列表
  local base_engines="bing,baidu,github,stackexchange,juejin,csdn,sinafinance,36kr"
  local international_engines="reuters,bbc,techcrunch,arstechnica,hackernews,economist,foreignaffairs"
  local searxng_engines="${base_engines}"
  local searxng_news_engines="baidu,bing news,sinafinance,36kr"

  if [[ "${SEARCH_MODE}" == "global" ]]; then
    searxng_engines="${base_engines},${international_engines}"
    searxng_news_engines="baidu,bing news,${international_engines},sinafinance,36kr"
    log "Global 模式：启用国际引擎 (${international_engines})"
  else
    log "GFW 模式：仅使用国内可用引擎"
  fi

  write_if_needed "${INSTALL_DIR}/deploy/.env" "SEARXNG_PORT=${SEARXNG_PORT}
ADAPTER_PORT=${ADAPTER_PORT}
SEARXNG_BASE_URL=http://127.0.0.1:${SEARXNG_PORT}/
SEARXNG_INTERNAL_URL=http://searxng:8080
INSTANCE_SECRET=${secret}
TAVILY_API_KEY=
LOCAL_MIN_RESULTS=3
REQUEST_TIMEOUT_MS=8000
ENGINE_TIMEOUT_MS=2500
RETRY_COUNT=1
RETRY_BACKOFF_MS=250
CACHE_TTL_SEC=1800
NEWS_CACHE_TTL_SEC=300
NEGATIVE_CACHE_TTL_SEC=120
RATE_LIMIT_RPM=30
BURST=10
ENABLE_TAVILY=true
SEARXNG_ENGINES=${searxng_engines}
SEARXNG_NEWS_ENGINES=${searxng_news_engines}
WEIGHT_EN_DEFAULT=0.65
WEIGHT_ZH_DEFAULT=0.35
WEIGHT_EN_TECH=0.75
WEIGHT_ZH_TECH=0.25
WEIGHT_EN_LOCAL=0.40
WEIGHT_ZH_LOCAL=0.60
ALLOW_CIDR=${ALLOW_CIDR}
"

  # 构建基础内置引擎
  local gfw_engines="      - bing
      - baidu
      - github
      - stackexchange"
  local global_engines="${gfw_engines}
      - google
      - wikipedia
      - duckduckgo
      - wolframalpha"
  local selected_engines=""
  if [[ "${SEARCH_MODE}" == "global" ]]; then
    selected_engines="${global_engines}"
  else
    selected_engines="${gfw_engines}"
  fi

  # 构建国际 RSS 引擎 (仅 Global 模式启用)
  local global_rss_engines=""
  if [[ "${SEARCH_MODE}" == "global" ]]; then
    global_rss_engines="
  # --- International RSS engines (Global mode) ---
  - name: economist
    engine: economist
    shortcut: eco
    categories: [news, finance]
    timeout: 8.0
  - name: foreignaffairs
    engine: foreignaffairs
    shortcut: fa
    categories: [news]
    timeout: 8.0
  - name: reuters
    engine: reuters
    shortcut: reuters
    categories: [news, general]
    timeout: 8.0
  - name: bbc
    engine: bbc
    shortcut: bbc
    categories: [news, general]
    timeout: 8.0
  - name: techcrunch
    engine: techcrunch
    shortcut: tc
    categories: [news, it, finance]
    timeout: 8.0
  - name: arstechnica
    engine: arstechnica
    shortcut: ars
    categories: [news, it]
    timeout: 8.0
  - name: hackernews
    engine: hackernews
    shortcut: hn
    categories: [news, it]
    timeout: 8.0"
  fi

  log "正在为 ${SEARCH_MODE} 模式生成 settings.yml..."
  local settings_content=""
  read -r -d '' settings_content << EOM
use_default_settings:
  engines:
    keep_only:
${selected_engines}

general:
  instance_name: "Hybrid Search Internal"
server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${secret}"
  limiter: false
search:
  default_lang: "zh-CN"
  formats:
    - html
    - json
outgoing:
  verify: false
  request_timeout: 10.0
valkey:
  url: redis://redis:6379/0

engines:
  # --- Custom engines (not in SearXNG defaults) ---
  - name: juejin
    engine: juejin
    shortcut: jj
    categories: [general, it]
    timeout: 4.0
  - name: csdn
    engine: csdn
    shortcut: cs
    categories: [general, it]
    timeout: 5.0

  # --- Finance & news engines (domestic, GFW-safe) ---
  - name: sinafinance
    engine: sinafinance
    shortcut: sfn
    categories: [finance, news, general]
    timeout: 5.0
  - name: 36kr
    engine: kr36
    shortcut: kr
    categories: [news, it]
    timeout: 6.0
${global_rss_engines}
EOM
use_default_settings: true
server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${secret}"
  limiter: false

ui:
  static_path: /usr/local/searxng/searxng-src/searxng/static
  theme: simple
  infinite_scroll: true

search:
  safe_search: 0
  autocomplete: ""

result_proxy:
  url: http://127.0.0.1:8080
  key: "${secret}"

redis:
  url: redis://redis:6379/0

engines:
${selected_engines}
EOM
  write_if_needed "${INSTALL_DIR}/searxng/settings.yml" "${settings_content}"

  # 复制其他静态文件
  if [[ -f "${DEPLOY_DIR}/searxng/limiter.toml" ]]; then
    copy_if_needed "${DEPLOY_DIR}/searxng/limiter.toml" "${INSTALL_DIR}/searxng/limiter.toml"
  fi
  copy_if_needed "${DEPLOY_DIR}/adapter/app.py" "${INSTALL_DIR}/adapter/app.py"
  copy_if_needed "${DEPLOY_DIR}/adapter/requirements.txt" "${INSTALL_DIR}/adapter/requirements.txt"
  copy_if_needed "${DEPLOY_DIR}/adapter/Dockerfile" "${INSTALL_DIR}/adapter/Dockerfile"
  copy_if_needed "${DEPLOY_DIR}/compose/docker-compose.yml" "${INSTALL_DIR}/deploy/docker-compose.yml"

  for engine_file in "${DEPLOY_DIR}/searxng/engines/"*.py; do
    [[ -f "${engine_file}" ]] || continue
    copy_if_needed "${engine_file}" "${INSTALL_DIR}/searxng/engines/$(basename "${engine_file}")"
  done
}

setup_firewall() {
  has_cmd firewall-cmd || { warn "未找到 firewall-cmd，跳过防火墙配置"; return; }
  systemctl is-active firewalld >/dev/null 2>&1 || { warn "firewalld 未运行，跳过防火墙配置"; return; }
  local r1="rule family=\"ipv4\" source address=\"${ALLOW_CIDR}\" port protocol=\"tcp\" port=\"${SEARXNG_PORT}\" accept"
  local r2="rule family=\"ipv4\" source address=\"${ALLOW_CIDR}\" port protocol=\"tcp\" port=\"${ADAPTER_PORT}\" accept"
  firewall-cmd --permanent --query-rich-rule="${r1}" >/dev/null 2>&1 || firewall-cmd --permanent --add-rich-rule="${r1}" >/dev/null
  firewall-cmd --permanent --query-rich-rule="${r2}" >/dev/null 2>&1 || firewall-cmd --permanent --add-rich-rule="${r2}" >/dev/null
  firewall-cmd --reload >/dev/null
}

start_stack() {
  cd "${INSTALL_DIR}/deploy"
  docker compose pull searxng redis || true
  docker compose up -d --build
}

print_next() {
  cat <<EOF
部署完成。
请执行以下检查：
  curl -fsS http://127.0.0.1:${SEARXNG_PORT}/
  curl -fsS http://127.0.0.1:${ADAPTER_PORT}/healthz
  curl -fsS -X POST http://127.0.0.1:${ADAPTER_PORT}/search -H 'Content-Type: application/json' -d '{"query":"python fastapi","max_results":5}'

如需启用 Tavily 兜底，请编辑：
  ${INSTALL_DIR}/deploy/.env  (设置 TAVILY_API_KEY)
EOF
}

main() {
  parse_args "$@"
  ensure_root
  install_prerequisites
  [[ -z "${ALLOW_CIDR}" ]] && ALLOW_CIDR="$(detect_vpc_cidr)"
  log "当前放行网段: ${ALLOW_CIDR}"
  install_docker
  install_compose_if_needed
  prepare_files
  setup_firewall
  start_stack
  print_next
}

main "$@"
