#!/bin/bash
# CoPaw install / upgrade / remove script for OpenCloudOS 8
# pip mirror: mirrors.aliyun.com/pypi
# Access via SSH tunnel: ssh -L 7077:localhost:7077 user@your_server_ip
#
# Prerequisites (run base/ scripts first):
#   bash ../base/01_system_base.sh         # system packages + mirrors
#   bash ../base/02_python312.sh           # Python 3.12
#   bash ../base/03_nodejs.sh --lts        # Node.js LTS
#   bash ../base/05_playwright.sh \
#        --venv /root/copaw-venv           # Playwright (run AFTER this script creates the venv)
#
# Usage:
#   ./install_copaw.sh          # install (idempotent)
#   ./install_copaw.sh upgrade  # upgrade copaw + agentscope
#   ./install_copaw.sh remove   # uninstall

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

VENV_PATH="/root/copaw-venv"
SERVICE_FILE="/etc/systemd/system/copaw.service"
MANAGE_SCRIPT="/root/copaw-manage.sh"
NVM_DIR="/root/.nvm"
PLAYWRIGHT_VER="1.56.0"

if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 权限运行此脚本"
    exit 1
fi

# =========================================
# Helpers
# =========================================
command_exists()          { command -v "$1" >/dev/null 2>&1; }
pip_package_installed()   { pip show "$1" >/dev/null 2>&1; }
python_import_ok()        { python -c "import $1" 2>/dev/null; }

load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

show_help() {
    echo "========================================="
    echo "CoPaw 管理脚本 (OpenCloudOS 8)"
    echo "========================================="
    echo "用法: $0 [选项]"
    echo "  无参数   安装（幂等）"
    echo "  upgrade  升级 copaw + agentscope"
    echo "  remove   彻底卸载"
    echo "  help     显示帮助"
    echo ""
}

# =========================================
# do_upgrade
# =========================================
do_upgrade() {
    log_info "开始升级 CoPaw..."
    [ ! -d "$VENV_PATH" ] && { log_error "未找到虚拟环境，请先安装"; exit 1; }
    source "$VENV_PATH/bin/activate"

    log_info "升级 agentscope..."
    pip install --upgrade agentscope

    log_info "升级 copaw..."
    pip install --upgrade copaw

    # Re-apply ChromaDB patch after upgrade
    _apply_chromadb_patch

    log_info "重启服务..."
    systemctl restart copaw.service 2>/dev/null || log_warning "服务重启失败，请手动检查"
    log_success "CoPaw 升级完成！"
    exit 0
}

# =========================================
# do_remove
# =========================================
do_remove() {
    log_warning "即将卸载 CoPaw，包括："
    echo "  - 停止并禁用服务"
    echo "  - 删除虚拟环境 $VENV_PATH"
    echo "  - 删除管理脚本 $MANAGE_SCRIPT"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    systemctl stop copaw.service 2>/dev/null || true
    systemctl disable copaw.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -rf "$VENV_PATH"
    rm -f "$MANAGE_SCRIPT"

    read -p "是否删除 CoPaw 配置文件？ (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf /root/.copaw /root/.config/copaw && log_info "配置文件已删除"

    read -p "是否删除 Playwright 浏览器缓存？ (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf /root/.cache/ms-playwright && log_info "浏览器缓存已删除"

    log_success "CoPaw 卸载完成！"
    exit 0
}

# =========================================
# ChromaDB SQLite patch helper
# =========================================
_apply_chromadb_patch() {
    SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])")
    CHROMADB_INIT="$SITE_PACKAGES/chromadb/__init__.py"
    if [ ! -f "$CHROMADB_INIT" ]; then
        log_warning "未找到 chromadb/__init__.py，跳过补丁"
        return
    fi
    if grep -q "import pysqlite3" "$CHROMADB_INIT" 2>/dev/null; then
        log_success "ChromaDB 补丁已存在"
        return
    fi
    log_info "应用 ChromaDB pysqlite3 补丁..."
    cp "$CHROMADB_INIT" "$CHROMADB_INIT.bak"
    cat > /tmp/chromadb_patch.py << 'PATCH'
import sys
try:
    import pysqlite3
    sys.modules['sqlite3'] = pysqlite3
except ImportError:
    pass
PATCH
    cat /tmp/chromadb_patch.py "$CHROMADB_INIT" > "$CHROMADB_INIT.new"
    mv "$CHROMADB_INIT.new" "$CHROMADB_INIT"
    log_success "ChromaDB 补丁已应用"
}

# =========================================
# do_install (main)
# =========================================
do_install() {
    echo "========================================="
    echo "CoPaw Install (OpenCloudOS 8)"
    echo "pip mirror: mirrors.aliyun.com/pypi"
    echo "Access: SSH Tunnel -> http://localhost:7077"
    echo "========================================="

    # ---- Preflight: check base prerequisites ----
    log_info "检查前置依赖..."
    if ! command_exists python3.12; then
        log_error "未找到 python3.12，请先运行: bash ../base/02_python312.sh"
        exit 1
    fi
    log_success "Python 3.12: $(python3.12 --version)"

    # ---- [1/7] Create virtualenv ----
    log_info "[1/7] 检查 Python 虚拟环境..."
    if [ ! -d "$VENV_PATH" ]; then
        log_info "创建虚拟环境 $VENV_PATH..."
        python3.12 -m venv "$VENV_PATH"
        log_success "虚拟环境创建完成"
    else
        log_success "虚拟环境已存在"
    fi
    source "$VENV_PATH/bin/activate"

    # ---- Configure pip mirror (always ensure) ----
    mkdir -p /root/.pip
    cat > /root/.pip/pip.conf << EOF
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
[install]
trusted-host = mirrors.aliyun.com
EOF

    # Inject mirror env into venv activate
    if ! grep -q "UV_INDEX_URL" "$VENV_PATH/bin/activate"; then
        echo 'export UV_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"' \
            >> "$VENV_PATH/bin/activate"
    fi

    # ---- [2/7] pysqlite3-binary ----
    log_info "[2/7] 检查 pysqlite3-binary..."
    if ! pip_package_installed pysqlite3-binary; then
        log_info "安装 pysqlite3-binary..."
        pip install --upgrade pip
        pip install pysqlite3-binary
        log_success "pysqlite3-binary 安装完成"
    else
        log_success "pysqlite3-binary 已安装"
    fi

    # ---- [3/7] uv ----
    log_info "[3/7] 检查 uv..."
    if ! pip_package_installed uv; then
        log_info "安装 uv..."
        pip install uv
        log_success "uv 安装完成"
    else
        log_success "uv 已安装"
    fi

    # ---- [4/7] agentscope + copaw ----
    log_info "[4/7] 检查 agentscope..."
    if ! python_import_ok agentscope; then
        log_info "安装 agentscope..."
        if ! pip install agentscope; then
            log_warning "pip 安装失败，尝试从 Gitee 源码安装..."
            cd /tmp
            [ ! -d "agentscope" ] && git clone https://gitee.com/modelscope/agentscope.git
            cd agentscope && pip install -e . && cd /root
            log_success "agentscope 源码安装完成"
        else
            log_success "agentscope 安装成功"
        fi
    else
        log_success "agentscope 已安装"
    fi

    log_info "检查 copaw..."
    if ! pip_package_installed copaw; then
        log_info "安装 copaw..."
        pip install copaw
        log_success "copaw 安装完成"
    else
        log_success "copaw 已安装"
    fi

    # ---- [5/7] Playwright Python package ----
    log_info "[5/7] 检查 Playwright Python 包..."
    CURRENT_PW_VER=$(pip show playwright 2>/dev/null | awk '/^Version:/{print $2}')
    if [ "$CURRENT_PW_VER" != "$PLAYWRIGHT_VER" ]; then
        [ -z "$CURRENT_PW_VER" ] \
            && log_info "安装 Playwright $PLAYWRIGHT_VER..." \
            || log_info "版本变更: $CURRENT_PW_VER -> $PLAYWRIGHT_VER"
        pip install --upgrade "playwright==$PLAYWRIGHT_VER"
        log_success "Playwright $PLAYWRIGHT_VER 安装完成"
    else
        log_success "Playwright $PLAYWRIGHT_VER 已安装"
    fi

    # Install Playwright browser (delegates to 05_playwright.sh logic inline)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BASE_DIR="$SCRIPT_DIR/../base"
    if [ -f "$BASE_DIR/05_playwright.sh" ]; then
        log_info "调用 base/05_playwright.sh 安装 Chromium..."
        bash "$BASE_DIR/05_playwright.sh" --venv "$VENV_PATH"
    else
        log_warning "未找到 base/05_playwright.sh，跳过 Chromium 安装"
        log_info "事后可运行: bash ../base/05_playwright.sh --venv $VENV_PATH"
    fi

    # ---- [6/7] ChromaDB + SQLite fix ----
    log_info "[6/7] 检查 ChromaDB 补丁..."
    _apply_chromadb_patch

    log_info "验证 Python SQLite 版本..."
    PY_SQLITE_VER=$(python -c "import sqlite3; print(sqlite3.sqlite_version)")
    log_success "Python SQLite 版本: $PY_SQLITE_VER"
    if [[ "$PY_SQLITE_VER" < "3.35.0" ]]; then
        log_warning "SQLite < 3.35.0，设置 LD_PRELOAD 兜底..."
        if ! grep -q "LD_PRELOAD" "$VENV_PATH/bin/activate"; then
            echo "export LD_PRELOAD=/usr/lib64/libsqlite3.so.0" >> "$VENV_PATH/bin/activate"
            log_success "LD_PRELOAD 已设置"
        fi
    fi

    # Inject nvm load into venv activate (Node.js used by Playwright / copaw)
    if ! grep -q "Load nvm" "$VENV_PATH/bin/activate"; then
        load_nvm  # ensure nvm is loaded in current shell too
        cat >> "$VENV_PATH/bin/activate" << 'NVMEOF'

# Load nvm (for Playwright / copaw Node.js usage)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVMEOF
        log_info "nvm 加载代码已注入 venv activate"
    fi

    # ---- [7/7] systemd service + manage script ----
    log_info "[7/7] 检查 systemd 服务..."
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CoPaw AI Assistant Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${VENV_PATH}/bin/copaw app --host 127.0.0.1 --port 7077
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable copaw.service
        log_success "systemd 服务已创建并启用"
    else
        log_success "systemd 服务已存在"
    fi

    if [ ! -f "$MANAGE_SCRIPT" ]; then
        cat > "$MANAGE_SCRIPT" << 'MANAGE'
#!/bin/bash
# CoPaw management script

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
VENV_PATH="/root/copaw-venv"

load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

case "$1" in
    start)    systemctl start copaw;   echo -e "${GREEN}CoPaw 已启动${NC}" ;;
    stop)     systemctl stop copaw;    echo -e "${YELLOW}CoPaw 已停止${NC}" ;;
    restart)  systemctl restart copaw; echo -e "${GREEN}CoPaw 已重启${NC}" ;;
    status)   systemctl status copaw ;;
    logs)     journalctl -u copaw -f ;;
    venv)
        source "$VENV_PATH/bin/activate"; load_nvm
        echo -e "${GREEN}已进入 CoPaw 虚拟环境${NC}"
        exec $SHELL
        ;;
    test)
        source "$VENV_PATH/bin/activate"; load_nvm
        echo -e "${BLUE}Python SQLite:${NC} $(python -c 'import sqlite3; print(sqlite3.sqlite_version)')"
        echo -e "${BLUE}Node:${NC}          $(node --version 2>/dev/null || echo '未安装')"
        echo -e "${BLUE}Playwright:${NC}    $(playwright --version 2>/dev/null || echo '未安装')"
        echo -e "${BLUE}copaw:${NC}         $(copaw --version 2>/dev/null || echo '未安装')"
        ;;
    init)
        source "$VENV_PATH/bin/activate"; load_nvm
        copaw init --defaults
        echo -e "${GREEN}CoPaw 初始化完成${NC}"
        ;;
    version)
        source "$VENV_PATH/bin/activate"; copaw --version ;;
    playwright-install)
        source "$VENV_PATH/bin/activate"; load_nvm
        export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"
        playwright install --with-deps
        echo -e "${GREEN}Playwright 浏览器已安装${NC}"
        ;;
    upgrade)
        bash "$(dirname "$0")/coPaw/install_copaw.sh" upgrade 2>/dev/null || \
        bash "$(cd "$(dirname "$0")"; pwd)/install_copaw.sh" upgrade
        ;;
    help|*)
        echo "用法: $0 {start|stop|restart|status|logs|venv|test|init|version|playwright-install|upgrade}"
        exit 1 ;;
esac
MANAGE
        chmod +x "$MANAGE_SCRIPT"
        log_success "管理脚本已创建: $MANAGE_SCRIPT"
    else
        log_success "管理脚本已存在"
    fi

    # ---- Done ----
    echo ""
    log_success "========================================="
    log_success "CoPaw 安装完成！"
    log_success "========================================="
    echo ""
    echo "  Python:     $(python3.12 --version 2>/dev/null)"
    echo "  SQLite:     $PY_SQLITE_VER"
    echo "  Node.js:    $(node --version 2>/dev/null || echo '未安装（需先跑 base/03_nodejs.sh）')"
    echo "  Playwright: $(pip show playwright 2>/dev/null | awk '/^Version:/{print $2}' || echo '未安装')"
    echo "  copaw:      $(pip show copaw 2>/dev/null | awk '/^Version:/{print $2}' || echo '未安装')"
    echo ""
    echo "管理命令: $MANAGE_SCRIPT {start|stop|restart|status|logs|venv|test|init}"
    echo ""
    echo -e "${BLUE}网页访问 CoPaw UI: (需保持 SSH 隧道连接)${NC}"
    echo "  1. 在您的电脑上运行: ssh -L 7077:localhost:7077 root@YOUR_SERVER_IP"
    echo "  2. 在浏览器中打开: http://localhost:7077"
    echo ""
    echo "首次启动："
    echo "  1. $MANAGE_SCRIPT init"
    echo "  2. $MANAGE_SCRIPT start"
    echo "  3. $MANAGE_SCRIPT logs"
    echo "========================================="
}

# =========================================
# Entry point
# =========================================
case "${1:-}" in
    upgrade)         do_upgrade ;;
    remove)          do_remove  ;;
    help|--help|-h)  show_help; exit 0 ;;
    "")              do_install ;;
    *)               log_error "未知参数: $1"; show_help; exit 1 ;;
esac
