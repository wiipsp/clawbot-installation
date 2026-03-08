#!/bin/bash
# OpenClaw install script for OpenCloudOS 8
# OpenClaw: https://github.com/openclaw/openclaw  (latest: 2026.3.2)
# Gateway port: 18789 (WebSocket, loopback-only)
# Access via SSH tunnel: ssh -L 18789:localhost:18789 user@your_server_ip
#
# Requires: Node.js >= 22
# Idempotent — safe to run multiple times
#
# Prerequisites:
#   bash ../base/01_system_base.sh
#   bash ../base/03_nodejs.sh --v22
#
# Usage:
#   sudo bash install_openclaw.sh         # install or check OpenClaw
#   sudo bash install_openclaw.sh upgrade # upgrade OpenClaw
#   sudo bash install_openclaw.sh remove  # uninstall all

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

NVM_DIR="/root/.nvm"
MANAGE_SCRIPT="/root/openclaw-manage.sh"
OPENCLAW_DIR="/root/.openclaw"
OPENCLAW_PORT=18789

# ---- Parse arguments ----
SUBCMD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        upgrade|remove|help|--help|-h) SUBCMD="$1"; shift ;;
        "") shift ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 权限运行此脚本"
    exit 1
fi

load_nvm() {
    export NVM_DIR="$NVM_DIR"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

show_help() {
    echo "========================================="
    echo "OpenClaw 安装脚本 (OpenCloudOS 8)"
    echo "========================================="
    echo "用法: $0 [命令]"
    echo "  无命令      安装/检查 OpenClaw（幂等）"
    echo "  upgrade     升级到最新版本"
    echo "  remove      彻底卸载"
    echo "  help        显示此帮助"
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
    log_info "升级 OpenClaw..."
    load_nvm
    export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"
    npm install -g openclaw@latest --ignore-scripts
    log_success "OpenClaw 已升级: $(openclaw --version 2>/dev/null || echo '版本未知')"

    log_info "重启 OpenClaw Gateway 服务..."
    openclaw gateway restart 2>/dev/null \
        || systemctl restart openclaw.service 2>/dev/null \
        || log_warning "服务重启失败，请手动执行: openclaw gateway restart"
    log_success "升级完成！"
    exit 0
}

# =========================================
# do_remove
# =========================================
do_remove() {
    log_warning "即将卸载 OpenClaw，包括："
    echo "  - 停止 Gateway 服务"
    echo "  - 卸载 Gateway systemd 服务"
    echo "  - 删除全局 npm 包"
    echo "  - 删除管理脚本 $MANAGE_SCRIPT"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    load_nvm

    openclaw gateway stop 2>/dev/null || true
    openclaw gateway uninstall 2>/dev/null || true

    systemctl stop openclaw.service 2>/dev/null || true
    systemctl disable openclaw.service 2>/dev/null || true
    rm -f /etc/systemd/system/openclaw.service
    systemctl daemon-reload 2>/dev/null || true

    npm uninstall -g openclaw --ignore-scripts 2>/dev/null || true
    rm -f "$MANAGE_SCRIPT"

    read -p "是否删除 OpenClaw 配置和工作目录 ($OPENCLAW_DIR)？ (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "$OPENCLAW_DIR" && log_info "工作目录已删除"

    log_success "OpenClaw 卸载完成！"
    exit 0
}

# =========================================
# do_install
# =========================================
do_install() {
    echo "========================================="
    echo "OpenClaw Install (OpenCloudOS 8)"
    echo "Version: latest (2026.3.2+)"
    echo "npm mirror: registry.npmmirror.com"
    echo "Access: SSH Tunnel -> http://localhost:${OPENCLAW_PORT}"
    echo "========================================="

    # ---- 1. Check Node.js >= 22 ----
    log_info "[1/4] 检查 Node.js 版本（需要 >= 22）..."
    load_nvm

    if ! command_exists node; then
        log_error "未找到 Node.js，请先运行: bash ../base/03_nodejs.sh --v22"
        exit 1
    fi

    NODE_VER=$(node --version | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VER" | cut -d'.' -f1)
    if [ "$NODE_MAJOR" -lt 22 ]; then
        log_error "Node.js $NODE_VER 不满足要求（需 >= 22）"
        log_info "请运行: bash ../base/03_nodejs.sh --v22"
        exit 1
    fi
    log_success "Node.js 符合要求: v$NODE_VER"

    # ---- 2. npm mirror ----
    log_info "[2/4] 配置 npm 国内镜像..."
    export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"
    timeout 10 npm config set registry https://registry.npmmirror.com 2>/dev/null \
        || log_warning "npm config 超时，继续..."
    log_success "npm 镜像: $(npm config get registry 2>/dev/null)"

    # ---- 3. Install openclaw npm package ----
    log_info "[3/4] 配置 git 走 HTTPS（避免 GFW 拦截 github SSH）..."
    git config --global url.'https://github.com/'.insteadOf git@github.com: 2>/dev/null || true
    git config --global url.'https://'.insteadOf ssh:// 2>/dev/null || true

    log_info "检查 OpenClaw npm 包..."
    if command_exists openclaw; then
        CURRENT_VER=$(openclaw --version 2>/dev/null || echo "已安装")
        log_success "OpenClaw 已安装: $CURRENT_VER"
    else
        log_info "安装 openclaw@latest..."
        npm install -g openclaw@latest --ignore-scripts
        log_success "OpenClaw 安装完成: $(openclaw --version 2>/dev/null)"
    fi

    # ---- 4. Install Gateway as system service ----
    log_info "[4/4] 安装 Gateway 系统服务..."
    if openclaw gateway status --no-probe 2>/dev/null | grep -q "installed\|running\|active"; then
        log_success "Gateway 服务已安装"
    else
        log_info "安装 Gateway 服务..."
        openclaw gateway install --port "$OPENCLAW_PORT" 2>/dev/null \
            || log_warning "gateway install 失败，可在 onboard 时完成"
    fi

    # ---- Create manage script ----
    cat > "$MANAGE_SCRIPT" << 'MANAGE_EOF'
#!/bin/bash
# OpenClaw management script

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NVM_DIR="/root/.nvm"
OPENCLAW_PORT=18789

load_nvm() {
    export NVM_DIR="$NVM_DIR"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

load_nvm

case "$1" in
    start)
        openclaw gateway start
        echo -e "${GREEN}OpenClaw Gateway 已启动${NC}"
        ;;
    stop)
        openclaw gateway stop
        echo -e "${YELLOW}OpenClaw Gateway 已停止${NC}"
        ;;
    restart)
        openclaw gateway restart
        echo -e "${GREEN}OpenClaw Gateway 已重启${NC}"
        ;;
    status)
        openclaw gateway status
        ;;
    health)
        openclaw gateway health --url ws://127.0.0.1:18789
        ;;
    logs)
        journalctl -u openclaw -f 2>/dev/null \
            || openclaw gateway call logs.tail --params '{"sinceMs":60000}'
        ;;
    onboard)
        echo -e "${YELLOW}启动 OpenClaw 初始化向导...${NC}"
        openclaw onboard --install-daemon
        ;;
    profile)
        if [ -z "$2" ]; then
            echo -e "${BLUE}当前 tools.profile:${NC} $(openclaw config get tools.profile 2>/dev/null || echo '未设置')"
            echo "可选值: full | coding | messaging | minimal"
        else
            openclaw config set tools.profile "$2"
            echo -e "${GREEN}tools.profile 已设置为: $2${NC}"
            openclaw gateway restart
        fi
        ;;
    upgrade)
        export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"
        npm install -g openclaw@latest --ignore-scripts
        openclaw gateway restart || true
        echo -e "${GREEN}OpenClaw 已升级${NC}"
        ;;
    version)
        openclaw --version
        ;;
    config)
        shift
        openclaw config "$@"
        ;;
    test)
        echo -e "${BLUE}Node 版本:${NC}     $(node --version)"
        echo -e "${BLUE}npm  版本:${NC}     $(npm --version)"
        echo -e "${BLUE}OpenClaw:${NC}      $(openclaw --version 2>/dev/null || echo '未安装')"
        echo -e "${BLUE}tools.profile:${NC} $(openclaw config get tools.profile 2>/dev/null || echo '未设置')"
        echo -e "${BLUE}Gateway:${NC}       $(openclaw gateway status --no-probe 2>/dev/null | head -1 || echo '未知')"
        PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo 'unknown')
        echo -e "${BLUE}公网 IP:${NC}       $PUBLIC_IP"
        echo -e "${BLUE}访问方式:${NC}      通过 SSH 隧道 (ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} root@${PUBLIC_IP})"
        ;;
    help|*)
        echo "用法: $0 {start|stop|restart|status|health|logs|onboard|profile|upgrade|version|config|test}"
        echo ""
        echo "  start              启动 Gateway 服务"
        echo "  stop               停止 Gateway 服务"
        echo "  restart            重启 Gateway 服务"
        echo "  status             查看服务状态"
        echo "  health             WebSocket 健康检查"
        echo "  logs               查看实时日志"
        echo "  onboard            运行初始化向导（首次安装后执行）"
        echo "  profile [value]    查看/设置 tools.profile (full|coding|messaging|minimal)"
        echo ""
        echo "  upgrade            升级到最新版"
        echo "  version            查看版本"
        echo "  config <args>      透传 openclaw config 命令"
        echo "  test               检查环境和访问方式"
        exit 1
        ;;
esac
MANAGE_EOF
    chmod +x "$MANAGE_SCRIPT"
    log_success "管理脚本已更新: $MANAGE_SCRIPT"

    # Done
    echo ""
    log_success "========================================="
    log_success "OpenClaw 安装完成！"
    log_success "========================================="
    echo ""
    echo "  Node.js:       $(node --version 2>/dev/null)"
    echo "  OpenClaw:      $(openclaw --version 2>/dev/null || echo '请重新登录 Shell')"
    echo "  Gateway 端口:  $OPENCLAW_PORT (WebSocket, loopback)"
    echo ""
    echo -e "${BLUE}网页访问 Control UI: (需保持 SSH 隧道连接)${NC}"
    echo "  1. 在您的电脑上运行: ssh -L ${OPENCLAW_PORT}:localhost:${OPENCLAW_PORT} root@YOUR_SERVER_IP"
    echo "  2. 在浏览器中打开: http://localhost:${OPENCLAW_PORT}"
    echo ""
    echo -e "${YELLOW}首次安装请执行初始化向导：${NC}"
    echo "  $MANAGE_SCRIPT onboard"
    echo ""
    echo -e "${GREEN}管理命令：${NC}"
    echo "  $MANAGE_SCRIPT {start|stop|restart|status|health|logs|onboard|profile|upgrade|test}"
    echo "========================================="
}

case "$SUBCMD" in
    upgrade)        do_upgrade ;;
    remove)         do_remove  ;;
    help|--help|-h) show_help; exit 0 ;;
    "")             do_install ;;
    *)              log_error "未知参数: $SUBCMD"; show_help; exit 1 ;;
esac
