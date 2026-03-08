#!/bin/bash
# Install Docker CE on OpenCloudOS 8
# Docker CE repo: mirrors.cloud.tencent.com (阿里云无此源)
# Docker daemon registry-mirrors: 腾讯云/中科大加速
# Idempotent — safe to run multiple times
#
# Usage:
#   sudo bash 04_docker.sh           # install (idempotent)
#   sudo bash 04_docker.sh remove    # uninstall Docker CE

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && { log_error "请以 root 权限运行"; exit 1; }

DAEMON_JSON="/etc/docker/daemon.json"
DESIRED_DAEMON='{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://dockerhub.timeweb.cloud",
    "https://docker.mirrors.ustc.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" }
}'

# =========================================
# remove
# =========================================
do_remove() {
    log_warning "将删除：docker-ce, docker-ce-cli, containerd.io, docker compose"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    dnf remove -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    rm -f /etc/yum.repos.d/docker-ce.repo
    rm -f /usr/local/lib/docker/cli-plugins/docker-compose
    log_success "Docker CE 已删除"
    exit 0
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    echo "========================================="
    echo "Docker CE Setup (OpenCloudOS 8)"
    echo "Repo: mirrors.cloud.tencent.com"
    echo "========================================="

    # --- 1. Docker CE ---
    log_info "[1/4] 检查 Docker CE..."
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker 已安装: $(docker --version)"
    else
        log_info "安装 Docker CE（腾讯云镜像）..."
        dnf config-manager --add-repo \
            https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo 2>/dev/null || \
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo

        sed -i 's|https://download.docker.com|https://mirrors.cloud.tencent.com/docker-ce|g' \
            /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true

        dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        log_success "Docker CE 安装完成"
    fi

    # --- 2. daemon.json (write only if content differs) ---
    log_info "[2/4] 检查 Docker daemon 镜像配置..."
    mkdir -p /etc/docker
    if [ "$(cat "$DAEMON_JSON" 2>/dev/null)" != "$DESIRED_DAEMON" ]; then
        echo "$DESIRED_DAEMON" > "$DAEMON_JSON"
        log_success "daemon.json 已更新"
    else
        log_success "daemon.json 无需更新"
    fi

    # --- 3. Enable + start (only reload if not running or config changed) ---
    log_info "[3/4] 检查 Docker 服务..."
    systemctl enable docker 2>/dev/null || true
    if ! systemctl is-active docker >/dev/null 2>&1; then
        systemctl start docker
        log_success "Docker 服务已启动"
    else
        systemctl reload-or-restart docker 2>/dev/null || true
        log_success "Docker 服务运行中（已重载配置）"
    fi

    # --- 4. Docker Compose ---
    log_info "[4/4] 检查 Docker Compose..."
    if docker compose version >/dev/null 2>&1; then
        log_success "docker compose 可用: $(docker compose version)"
    else
        log_info "安装 docker compose 独立版本..."
        COMPOSE_VER="v2.23.0"
        COMPOSE_BIN="/usr/local/lib/docker/cli-plugins/docker-compose"
        mkdir -p "$(dirname "$COMPOSE_BIN")"
        curl -fsSL \
            "https://mirrors.cloud.tencent.com/docker-compose/${COMPOSE_VER}/docker-compose-linux-x86_64" \
            -o "$COMPOSE_BIN" 2>/dev/null || \
        curl -fsSL \
            "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-x86_64" \
            -o "$COMPOSE_BIN"
        chmod +x "$COMPOSE_BIN"
        log_success "docker compose 安装完成"
    fi

    echo ""
    log_success "========================================="
    log_success "Docker 安装完成！"
    log_success "========================================="
    echo "  Docker:  $(docker --version)"
    echo "  Compose: $(docker compose version 2>/dev/null)"
    echo "  镜像加速: mirror.ccs.tencentyun.com"
    echo "========================================="
}

case "${1:-}" in
    remove) do_remove ;;
    "")     do_install ;;
    *)      log_error "未知参数: $1  (支持: remove)"; exit 1 ;;
esac
