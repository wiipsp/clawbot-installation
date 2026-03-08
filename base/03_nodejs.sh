#!/bin/bash
# Install Node.js via nvm on OpenCloudOS 8
# nvm: Gitee mirror  |  Node binaries: npmmirror.com  |  npm: registry.npmmirror.com
# Idempotent — safe to run multiple times
#
# Usage:
#   sudo bash 03_nodejs.sh              # install latest LTS (currently v24)
#   sudo bash 03_nodejs.sh --lts        # same as above
#   sudo bash 03_nodejs.sh --v24        # install Node.js 24 LTS (current LTS)
#   sudo bash 03_nodejs.sh --v22        # install Node.js 22 (required for OpenClaw)
#   sudo bash 03_nodejs.sh --v20        # install Node.js 20
#   sudo bash 03_nodejs.sh remove       # uninstall nvm + Node.js

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && { log_error "请以 root 权限运行"; exit 1; }

NVM_DIR="/root/.nvm"

# =========================================
# remove
# =========================================
do_remove() {
    log_warning "将删除：nvm (~/.nvm) 以及 /usr/local/bin 中的 node/npm/npx 软链接"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    rm -rf "$NVM_DIR"
    rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx
    # Remove nvm load lines from clawbot_mirrors.sh
    if [ -f /etc/profile.d/clawbot_mirrors.sh ]; then
        grep -v "nvm" /etc/profile.d/clawbot_mirrors.sh > /tmp/mirrors_tmp.sh || true
        mv /tmp/mirrors_tmp.sh /etc/profile.d/clawbot_mirrors.sh
    fi
    log_success "nvm 和 Node.js 已删除"
    exit 0
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    # Parse version flag
    NODE_TARGET="lts/*"
    NODE_LABEL="latest LTS"
    case "${1:-}" in
        --v24) NODE_TARGET="24"; NODE_LABEL="24 LTS (current LTS)" ;;
        --v22) NODE_TARGET="22"; NODE_LABEL="22 (required for OpenClaw)" ;;
        --v20) NODE_TARGET="20"; NODE_LABEL="20 LTS" ;;
        --lts) NODE_TARGET="lts/*"; NODE_LABEL="latest LTS" ;;
        "")    : ;;
        *)     log_error "未知参数: $1  (支持: --lts / --v24 / --v22 / --v20 / remove)"; exit 1 ;;
    esac

    echo "========================================="
    echo "Node.js Setup via nvm (OpenCloudOS 8)"
    echo "Target: $NODE_LABEL  |  Mirror: npmmirror.com"
    echo "========================================="

    # --- 1. nvm ---
    log_info "[1/4] 检查 nvm..."
    if [ -d "$NVM_DIR" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
        log_success "nvm 已安装"
    else
        log_info "安装 nvm（Gitee 镜像）..."
        export NVM_DIR="$NVM_DIR"
        curl -fsSL https://gitee.com/mirrors/nvm/raw/master/install.sh | bash
        log_success "nvm 安装完成"
    fi

    export NVM_DIR="$NVM_DIR"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # --- 2. Node.js download mirror ---
    log_info "[2/4] 配置 Node.js 下载镜像..."
    export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
    MIRROR_FILE="/etc/profile.d/clawbot_mirrors.sh"
    if [ -f "$MIRROR_FILE" ] && ! grep -q "NVM_NODEJS_ORG_MIRROR" "$MIRROR_FILE"; then
        cat >> "$MIRROR_FILE" << 'EOF'
export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
[ -s "$HOME/.nvm/nvm.sh" ] && \. "$HOME/.nvm/nvm.sh"
EOF
    fi
    log_success "Node.js 下载镜像: npmmirror.com"

    # --- 3. Node.js version ---
    log_info "[3/4] 检查 Node.js $NODE_LABEL..."
    INSTALLED_VER=$(node --version 2>/dev/null || echo "")
    NEED_INSTALL=0
    if [ -z "$INSTALLED_VER" ]; then
        NEED_INSTALL=1
    elif [ "$NODE_TARGET" = "24" ] && ! echo "$INSTALLED_VER" | grep -q "^v24\."; then
        log_info "已装 $INSTALLED_VER，需安装 Node 24..."
        NEED_INSTALL=1
    elif [ "$NODE_TARGET" = "22" ] && ! echo "$INSTALLED_VER" | grep -q "^v22\."; then
        log_info "已装 $INSTALLED_VER，需安装 Node 22..."
        NEED_INSTALL=1
    elif [ "$NODE_TARGET" = "20" ] && ! echo "$INSTALLED_VER" | grep -q "^v20\."; then
        log_info "已装 $INSTALLED_VER，需安装 Node 20..."
        NEED_INSTALL=1
    else
        log_success "Node.js 已满足要求: $INSTALLED_VER"
    fi

    if [ "$NEED_INSTALL" -eq 1 ]; then
        nvm install "$NODE_TARGET"
        nvm alias default "$NODE_TARGET"
        log_success "Node.js 安装完成: $(node --version)"
    fi

    # Always refresh symlinks (idempotent, ln -sf is safe)
    NODE_VERSION=$(nvm current)
    NODE_BIN="$NVM_DIR/versions/node/$NODE_VERSION/bin"
    if [ -d "$NODE_BIN" ]; then
        ln -sf "$NODE_BIN/node" /usr/local/bin/node
        ln -sf "$NODE_BIN/npm"  /usr/local/bin/npm
        ln -sf "$NODE_BIN/npx"  /usr/local/bin/npx
        log_success "软链接已更新: /usr/local/bin/{node,npm,npx} -> $NODE_BIN"
    fi

    # --- 4. npm mirror ---
    log_info "[4/4] 配置 npm 国内镜像..."
    timeout 10 npm config set registry https://registry.npmmirror.com 2>/dev/null \
        || log_warning "npm registry 配置超时，可继续"
    timeout 10 npm config set disturl https://npmmirror.com/mirrors/node 2>/dev/null \
        || log_warning "npm disturl 配置超时，可继续"

    echo ""
    log_success "========================================="
    log_success "Node.js 安装完成！"
    log_success "========================================="
    echo "  Node: $(node --version 2>/dev/null)"
    echo "  npm:  $(npm --version 2>/dev/null)"
    echo "  registry: $(npm config get registry 2>/dev/null)"
    echo "========================================="
}

case "${1:-}" in
    remove) do_remove ;;
    *)      do_install "$1" ;;
esac
