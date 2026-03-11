#!/bin/bash
# OpenClaw Docker install script for OpenCloudOS 8
# Image: ghcr.io/openclaw/openclaw:latest
# Gateway port: 18789 (WebSocket, loopback-only)
# Access via SSH tunnel: ssh -L 18789:localhost:18789 user@your_server_ip
#
# Requires: Docker CE + Docker Compose v2
# Idempotent — safe to run multiple times
#
# Prerequisites:
#   bash ../base/01_system_base.sh
#   bash ../base/04_docker.sh
#
# Usage:
#   sudo bash install_openclaw_docker.sh                 # install
#   sudo bash install_openclaw_docker.sh upgrade         # pull latest image & restart
#   sudo bash install_openclaw_docker.sh remove          # uninstall all
#   sudo bash install_openclaw_docker.sh --with-proxy    # install with Clash proxy for image pull

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

MANAGE_SCRIPT="/root/openclaw-manage.sh"
OPENCLAW_DIR="/root/.openclaw"
OPENCLAW_PORT=18789
INSTALL_DIR="/root/openclaw-docker"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_SRC="${SCRIPT_DIR}/docker/docker-compose.yml"
CLASH_PROXY="http://127.0.0.1:7890"

SUBCMD=""
WITH_PROXY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        upgrade|remove|help|--help|-h) SUBCMD="$1"; shift ;;
        --with-proxy) WITH_PROXY=1; shift ;;
        "") shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 权限运行此脚本"
    exit 1
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

clash_is_running() {
    curl -s --connect-timeout 2 http://127.0.0.1:9090/version >/dev/null 2>&1
}

setup_docker_proxy() {
    if [[ "$WITH_PROXY" -eq 0 ]]; then
        return
    fi
    if ! clash_is_running; then
        log_warning "Clash 代理未运行（9090 无响应），跳过 Docker 代理配置"
        return
    fi
    log_info "配置 Docker daemon 使用 Clash 代理拉取镜像..."
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/proxy.conf << EOF
[Service]
Environment="HTTP_PROXY=${CLASH_PROXY}"
Environment="HTTPS_PROXY=${CLASH_PROXY}"
Environment="NO_PROXY=localhost,127.0.0.1,mirror.ccs.tencentyun.com,registry.npmmirror.com"
EOF
    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker daemon 代理已配置: ${CLASH_PROXY}"
}

remove_docker_proxy() {
    if [[ -f /etc/systemd/system/docker.service.d/proxy.conf ]]; then
        rm -f /etc/systemd/system/docker.service.d/proxy.conf
        systemctl daemon-reload
        systemctl restart docker
        log_info "Docker daemon 代理配置已移除"
    fi
}

show_help() {
    echo "========================================="
    echo "OpenClaw Docker 安装脚本 (OpenCloudOS 8)"
    echo "========================================="
    echo "用法: $0 [命令] [选项]"
    echo ""
    echo "命令:"
    echo "  无命令      安装/检查 OpenClaw Docker（幂等）"
    echo "  upgrade     拉取最新镜像并重启"
    echo "  remove      彻底卸载"
    echo "  help        显示此帮助"
    echo ""
    echo "选项:"
    echo "  --with-proxy  使用 Clash 代理拉取 ghcr.io 镜像（解决 GFW 限制）"
    echo ""
    echo "访问方式: 通过 SSH 隧道"
    echo "  ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} root@YOUR_SERVER_IP"
    echo "  然后在浏览器打开: http://localhost:${OPENCLAW_PORT}"
    echo ""
}

# =========================================
# do_upgrade
# =========================================
do_upgrade() {
    log_info "升级 OpenClaw Docker..."
    setup_docker_proxy

    cd "${INSTALL_DIR}"
    docker compose pull openclaw-gateway
    docker compose up -d openclaw-gateway
    remove_docker_proxy

    log_success "OpenClaw Docker 已升级"
    docker compose ps
    exit 0
}

# =========================================
# do_remove
# =========================================
do_remove() {
    log_warning "即将卸载 OpenClaw Docker，包括："
    echo "  - 停止并删除容器"
    echo "  - 删除运行时目录 ${INSTALL_DIR}"
    echo "  - 删除管理脚本 ${MANAGE_SCRIPT}"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    if [[ -d "${INSTALL_DIR}" ]]; then
        cd "${INSTALL_DIR}" && docker compose down 2>/dev/null || true
    fi
    rm -rf "${INSTALL_DIR}"
    rm -f "${MANAGE_SCRIPT}"
    remove_docker_proxy

    read -p "是否删除 OpenClaw 配置和工作目录 (${OPENCLAW_DIR})？ (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "${OPENCLAW_DIR}" && log_info "工作目录已删除"

    log_success "OpenClaw Docker 卸载完成！"
    exit 0
}

# =========================================
# do_install
# =========================================
do_install() {
    echo "========================================="
    echo "OpenClaw Docker Install (OpenCloudOS 8)"
    echo "Image: ghcr.io/openclaw/openclaw:latest"
    echo "Access: SSH Tunnel -> http://localhost:${OPENCLAW_PORT}"
    echo "========================================="

    # ---- 1. Check Docker ----
    log_info "[1/5] 检查 Docker..."
    if ! command_exists docker; then
        log_error "未找到 Docker，请先运行: bash ../base/04_docker.sh"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log_error "未找到 Docker Compose v2，请先运行: bash ../base/04_docker.sh"
        exit 1
    fi
    log_success "Docker 已安装: $(docker --version | head -c 50)"

    # ---- 2. Setup proxy for image pull (optional) ----
    log_info "[2/5] 检查镜像拉取环境..."
    setup_docker_proxy

    # ---- 3. Prepare compose files ----
    log_info "[3/5] 准备 Docker Compose 文件..."
    mkdir -p "${INSTALL_DIR}" "${OPENCLAW_DIR}" "${OPENCLAW_DIR}/workspace"

    if [[ ! -f "${COMPOSE_SRC}" ]]; then
        log_error "缺少 Docker Compose 源文件: ${COMPOSE_SRC}"
        exit 1
    fi
    cp "${COMPOSE_SRC}" "${INSTALL_DIR}/docker-compose.yml"
    log_success "Compose 文件已复制到 ${INSTALL_DIR}/"

    # Generate .env
    local gateway_token
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        log_info "保留已有 .env 文件"
    else
        gateway_token="$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        cat > "${INSTALL_DIR}/.env" << EOF
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest
OPENCLAW_GATEWAY_PORT=${OPENCLAW_PORT}
OPENCLAW_CONFIG_DIR=${OPENCLAW_DIR}
OPENCLAW_WORKSPACE_DIR=${OPENCLAW_DIR}/workspace

# AI provider proxy (via Clash, leave empty if not needed)
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=localhost,127.0.0.1
EOF
        log_success ".env 文件已生成"
    fi

    # ---- 4. Pull image & start ----
    log_info "[4/5] 拉取镜像并启动..."
    cd "${INSTALL_DIR}"
    docker compose pull openclaw-gateway
    docker compose up -d openclaw-gateway

    remove_docker_proxy

    # ---- 5. Set tools.profile = full ----
    log_info "[5/5] 设置 tools.profile = full..."
    sleep 5
    local retries=0
    while ! curl -fsS http://127.0.0.1:${OPENCLAW_PORT}/healthz >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [[ $retries -ge 12 ]]; then
            log_warning "Gateway 健康检查超时（60s），请稍后手动执行: ${MANAGE_SCRIPT} profile full"
            break
        fi
        sleep 5
    done

    if curl -fsS http://127.0.0.1:${OPENCLAW_PORT}/healthz >/dev/null 2>&1; then
        docker compose run --rm -T openclaw-cli config set tools.profile full 2>/dev/null \
            && log_success "tools.profile = full 已设置" \
            || log_warning "tools.profile 设置失败，请手动执行: ${MANAGE_SCRIPT} profile full"
    fi

    # gateway.bind must be lan for Docker port publishing to work
    docker compose run --rm -T openclaw-cli config set gateway.bind lan 2>/dev/null \
        && log_success "gateway.bind = lan 已设置" \
        || log_warning "gateway.bind 设置失败，请手动执行: ${MANAGE_SCRIPT} config set gateway.bind lan"
    docker compose restart openclaw-gateway 2>/dev/null || true

    # ---- Create manage script ----
    cat > "${MANAGE_SCRIPT}" << 'MANAGE_EOF'
#!/bin/bash
# OpenClaw Docker management script

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/root/openclaw-docker"
OPENCLAW_PORT=18789

cd "${INSTALL_DIR}" 2>/dev/null || { echo -e "${RED}未找到安装目录: ${INSTALL_DIR}${NC}"; exit 1; }

case "$1" in
    start)
        docker compose up -d openclaw-gateway
        echo -e "${GREEN}OpenClaw Gateway 已启动${NC}"
        ;;
    stop)
        docker compose down
        echo -e "${YELLOW}OpenClaw Gateway 已停止${NC}"
        ;;
    restart)
        docker compose restart openclaw-gateway
        echo -e "${GREEN}OpenClaw Gateway 已重启${NC}"
        ;;
    status)
        docker compose ps
        ;;
    health)
        curl -fsS http://127.0.0.1:${OPENCLAW_PORT}/healthz && echo ""
        curl -fsS http://127.0.0.1:${OPENCLAW_PORT}/readyz && echo ""
        ;;
    logs)
        docker compose logs -f openclaw-gateway
        ;;
    onboard)
        echo -e "${YELLOW}启动 OpenClaw 初始化向导...${NC}"
        docker compose run --rm openclaw-cli onboard --install-daemon
        ;;
    profile)
        if [ -z "$2" ]; then
            echo -e "${BLUE}当前 tools.profile:${NC} $(docker compose run --rm -T openclaw-cli config get tools.profile 2>/dev/null || echo '未设置')"
            echo "可选值: full | coding | messaging | minimal"
        else
            docker compose run --rm -T openclaw-cli config set tools.profile "$2"
            echo -e "${GREEN}tools.profile 已设置为: $2${NC}"
            docker compose restart openclaw-gateway
        fi
        ;;
    upgrade)
        docker compose pull openclaw-gateway
        docker compose up -d openclaw-gateway
        echo -e "${GREEN}OpenClaw 已升级${NC}"
        ;;
    version)
        docker compose run --rm -T openclaw-cli --version
        ;;
    config)
        shift
        docker compose run --rm -T openclaw-cli config "$@"
        ;;
    dashboard)
        docker compose run --rm openclaw-cli dashboard --no-open
        ;;
    inject-proxy)
        PROXY_URL="${2:-http://host.docker.internal:7890}"
        sed -i "s|^HTTP_PROXY=.*|HTTP_PROXY=${PROXY_URL}|" "${INSTALL_DIR}/.env"
        sed -i "s|^HTTPS_PROXY=.*|HTTPS_PROXY=${PROXY_URL}|" "${INSTALL_DIR}/.env"
        docker compose up -d openclaw-gateway
        echo -e "${GREEN}已注入代理 ${PROXY_URL} 并重启 Gateway${NC}"
        ;;
    test)
        echo -e "${BLUE}Docker:${NC}        $(docker --version | head -c 50)"
        echo -e "${BLUE}Compose:${NC}       $(docker compose version | head -c 50)"
        echo -e "${BLUE}OpenClaw:${NC}      $(docker compose run --rm -T openclaw-cli --version 2>/dev/null || echo '未运行')"
        echo -e "${BLUE}tools.profile:${NC} $(docker compose run --rm -T openclaw-cli config get tools.profile 2>/dev/null || echo '未设置')"
        echo -e "${BLUE}Gateway:${NC}       $(docker compose ps --format '{{.Status}}' openclaw-gateway 2>/dev/null || echo '未知')"
        PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo 'unknown')
        echo -e "${BLUE}公网 IP:${NC}       ${PUBLIC_IP}"
        echo -e "${BLUE}访问方式:${NC}      通过 SSH 隧道 (ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} root@${PUBLIC_IP})"
        ;;
    help|*)
        echo "用法: $0 {start|stop|restart|status|health|logs|onboard|profile|upgrade|version|config|dashboard|inject-proxy|test}"
        echo ""
        echo "  start                 启动 Gateway 容器"
        echo "  stop                  停止并删除容器"
        echo "  restart               重启 Gateway 容器"
        echo "  status                查看容器状态"
        echo "  health                健康检查 (healthz + readyz)"
        echo "  logs                  查看实时日志"
        echo "  onboard               运行初始化向导（首次安装后执行）"
        echo "  profile [value]       查看/设置 tools.profile (full|coding|messaging|minimal)"
        echo ""
        echo "  upgrade               拉取最新镜像并重启"
        echo "  version               查看版本"
        echo "  config <args>         透传 openclaw config 命令"
        echo "  dashboard             获取 Control UI 访问链接"
        echo "  inject-proxy [url]    注入 AI 代理并重启 (默认: http://host.docker.internal:7890)"
        echo "  test                  检查环境和访问方式"
        exit 1
        ;;
esac
MANAGE_EOF
    chmod +x "${MANAGE_SCRIPT}"
    log_success "管理脚本已更新: ${MANAGE_SCRIPT}"

    # Done
    echo ""
    log_success "========================================="
    log_success "OpenClaw Docker 安装完成！"
    log_success "========================================="
    echo ""
    echo "  Docker:        $(docker --version | head -c 50)"
    echo "  Image:         ghcr.io/openclaw/openclaw:latest"
    echo "  Gateway 端口:  ${OPENCLAW_PORT} (WebSocket, loopback)"
    echo "  Compose 目录:  ${INSTALL_DIR}"
    echo ""
    echo -e "${BLUE}网页访问 Control UI: (需保持 SSH 隧道连接)${NC}"
    echo "  1. 在您的电脑上运行: ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} root@YOUR_SERVER_IP"
    echo "  2. 在浏览器中打开: http://localhost:${OPENCLAW_PORT}"
    echo ""
    echo -e "${YELLOW}首次安装请执行初始化向导：${NC}"
    echo "  ${MANAGE_SCRIPT} onboard"
    echo ""
    echo -e "${GREEN}管理命令：${NC}"
    echo "  ${MANAGE_SCRIPT} {start|stop|restart|status|health|logs|onboard|profile|upgrade|dashboard|test}"
    echo ""
    echo -e "${YELLOW}如需 AI 代理（Clash）访问 Claude/OpenRouter：${NC}"
    echo "  ${MANAGE_SCRIPT} inject-proxy"
    echo "========================================="
}

case "$SUBCMD" in
    upgrade)        do_upgrade ;;
    remove)         do_remove  ;;
    help|--help|-h) show_help; exit 0 ;;
    "")             do_install ;;
    *)              log_error "未知参数: $SUBCMD"; show_help; exit 1 ;;
esac
