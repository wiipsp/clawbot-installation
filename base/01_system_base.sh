#!/bin/bash
# Base system setup for OpenCloudOS 8
# Mirror strategy:
#   EPEL/dnf -> mirrors.aliyun.com  |  pip/uv -> mirrors.aliyun.com/pypi
#   npm/node -> npmmirror.com       |  Docker CE repo -> mirrors.cloud.tencent.com
#   Playwright -> cdn.npmmirror.com
#
# Usage:
#   sudo bash 01_system_base.sh           # install (idempotent)
#   sudo bash 01_system_base.sh remove    # remove EPEL + clean mirror configs

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && { log_error "请以 root 权限运行"; exit 1; }

# =========================================
# remove
# =========================================
do_remove() {
    log_warning "将删除：EPEL、全局镜像配置、pip.conf（系统基础包保留）"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    dnf remove -y epel-release 2>/dev/null || true
    rm -f /etc/profile.d/clawbot_mirrors.sh
    rm -f /root/.pip/pip.conf
    log_success "清理完成（系统基础包未删除，如需删除请手动执行 dnf remove）"
    exit 0
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    echo "========================================="
    echo "Base System Setup (OpenCloudOS 8)"
    echo "Mirror: Aliyun (pip/dnf) + npmmirror (node)"
    echo "========================================="

    # --- 1. EPEL + dnf mirror ---
    log_info "[1/4] 配置 EPEL 阿里云镜像..."
    rm -f /etc/yum.repos.d/nodesource*.repo 2>/dev/null || true
    dnf clean all

    if ! rpm -q epel-release >/dev/null 2>&1; then
        log_info "安装 EPEL（阿里云镜像）..."
        dnf install -y https://mirrors.aliyun.com/epel/epel-release-latest-8.noarch.rpm || \
        dnf install -y epel-release
    else
        log_success "EPEL 已安装"
    fi

    if [ -f /etc/yum.repos.d/epel.repo ]; then
        sed -i \
            -e 's|https://download.fedoraproject.org/pub/epel|https://mirrors.aliyun.com/epel|g' \
            -e 's|^metalink=|#metalink=|g' \
            -e 's|^#baseurl=|baseurl=|g' \
            /etc/yum.repos.d/epel.repo 2>/dev/null || true
    fi
    log_success "DNF/EPEL 阿里云镜像配置完成"

    # --- 2. System packages ---
    log_info "[2/4] 安装系统基础包..."
    SYSTEM_PACKAGES=(
        dnf-plugins-core git curl wget vim tar unzip
        openssl openssl-devel ca-certificates
        sqlite sqlite-devel bzip2-devel libffi-devel
        xz-devel zlib-devel readline-devel ncurses-devel
        gdbm-devel libuuid-devel expat-devel
    )
    MISSING=()
    for pkg in "${SYSTEM_PACKAGES[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        log_info "安装缺失包: ${MISSING[*]}"
        dnf install -y "${MISSING[@]}"
    else
        log_success "所有系统基础包已安装"
    fi

    # --- 3. Development Tools ---
    log_info "[3/4] 检查 Development Tools..."
    if ! rpm -q gcc gcc-c++ make >/dev/null 2>&1; then
        dnf groupinstall -y "Development Tools"
        log_success "Development Tools 安装完成"
    else
        log_success "Development Tools 已安装"
    fi

    # --- 4. Global mirror env vars ---
    log_info "[4/4] 写入全局镜像环境变量..."
    ENV_FILE="/etc/profile.d/clawbot_mirrors.sh"
    # Always overwrite to ensure correctness
    cat > "$ENV_FILE" << 'EOF'
# Clawbot: GFW-friendly mirror config for OpenCloudOS 8
export PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
export PIP_TRUSTED_HOST="mirrors.aliyun.com"
export UV_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"
export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"
[ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
EOF
    chmod 644 "$ENV_FILE"
    source "$ENV_FILE"
    log_success "全局镜像配置已写入 $ENV_FILE"

    mkdir -p /root/.pip
    # Only write pip.conf if content differs
    DESIRED_PIP_CONF="[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
[install]
trusted-host = mirrors.aliyun.com"
    if [ "$(cat /root/.pip/pip.conf 2>/dev/null)" != "$DESIRED_PIP_CONF" ]; then
        echo "$DESIRED_PIP_CONF" > /root/.pip/pip.conf
        log_success "pip 阿里云镜像配置完成"
    else
        log_success "pip.conf 无需更新"
    fi

    echo ""
    log_success "========================================="
    log_success "系统基础安装完成！"
    log_success "========================================="
    echo "  EPEL 镜像:   mirrors.aliyun.com/epel"
    echo "  pip 镜像:    mirrors.aliyun.com/pypi"
    echo "  npm 镜像:    registry.npmmirror.com"
    echo "  全局配置:    $ENV_FILE"
    echo ""
    echo "下一步："
    echo "  bash 02_python312.sh  |  bash 03_nodejs.sh  |  bash 04_docker.sh"
    echo "========================================="
}

case "${1:-}" in
    remove) do_remove ;;
    "")     do_install ;;
    *)      log_error "未知参数: $1  (支持: remove)"; exit 1 ;;
esac
