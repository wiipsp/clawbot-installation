#!/bin/bash
# Install Python 3.12 on OpenCloudOS 8
# pip mirror: mirrors.aliyun.com/pypi
# Idempotent — safe to run multiple times
#
# Usage:
#   sudo bash 02_python312.sh           # install (idempotent)
#   sudo bash 02_python312.sh remove    # uninstall python3.12 + pip.conf

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
    log_warning "将删除：python3.12 / python3.12-devel 以及 pip.conf"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    dnf remove -y python3.12 python3.12-devel 2>/dev/null || true
    rm -f /usr/bin/python3.12 /usr/local/bin/python3.12
    rm -f /root/.pip/pip.conf
    log_success "Python 3.12 已删除"
    exit 0
}

# =========================================
# Helper: compile from source (fallback)
# =========================================
_install_python312_from_source() {
    local ver="3.12.9"
    local src_dir="/tmp/Python-${ver}"
    log_info "从腾讯云镜像下载 Python ${ver} 源码（阿里云无此源）..."
    cd /tmp
    if [ ! -f "Python-${ver}.tgz" ]; then
        curl -fsSL "https://mirrors.cloud.tencent.com/python/${ver}/Python-${ver}.tgz" \
            -o "Python-${ver}.tgz" || \
        curl -fsSL "https://www.python.org/ftp/python/${ver}/Python-${ver}.tgz" \
            -o "Python-${ver}.tgz"
    fi
    tar -xzf "Python-${ver}.tgz"
    cd "$src_dir"
    ./configure --enable-optimizations --prefix=/usr/local
    make -j"$(nproc)"
    make altinstall
    ln -sf /usr/local/bin/python3.12 /usr/bin/python3.12 2>/dev/null || true
    log_success "Python 3.12 源码编译安装完成"
    cd /root
    rm -rf "$src_dir" "/tmp/Python-${ver}.tgz"
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    echo "========================================="
    echo "Python 3.12 Setup (OpenCloudOS 8)"
    echo "pip mirror: mirrors.aliyun.com/pypi"
    echo "========================================="

    # --- 1. Python 3.12 ---
    log_info "[1/3] 检查 Python 3.12..."
    if command -v python3.12 >/dev/null 2>&1; then
        log_success "Python 3.12 已安装: $(python3.12 --version)"
    else
        log_info "安装 Python 3.12..."
        if dnf install -y python3.12 python3.12-devel; then
            log_success "Python 3.12 安装完成（dnf）"
        else
            log_warning "dnf 安装失败，从源码编译..."
            _install_python312_from_source
        fi
    fi

    # --- 2. pip ---
    log_info "[2/3] 检查 pip3.12..."
    if python3.12 -m pip --version >/dev/null 2>&1; then
        log_success "pip3.12 已可用: $(python3.12 -m pip --version)"
    else
        log_info "安装 pip..."
        dnf install -y python3.12-pip 2>/dev/null || \
        python3.12 -m ensurepip --upgrade || \
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | python3.12
        log_success "pip3.12 安装完成"
    fi

    # --- 3. pip mirror (write only if needed) ---
    log_info "[3/3] 配置 pip 阿里云镜像..."
    mkdir -p /root/.pip
    DESIRED="[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
[install]
trusted-host = mirrors.aliyun.com"
    if [ "$(cat /root/.pip/pip.conf 2>/dev/null)" != "$DESIRED" ]; then
        echo "$DESIRED" > /root/.pip/pip.conf
        log_success "pip.conf 已更新"
    else
        log_success "pip.conf 无需更新"
    fi

    python3.12 -m pip install --upgrade pip -q

    echo ""
    log_success "========================================="
    log_success "Python 3.12 安装完成！"
    log_success "========================================="
    echo "  Python: $(python3.12 --version)"
    echo "  pip:    $(python3.12 -m pip --version)"
    echo "  镜像:   mirrors.aliyun.com/pypi"
    echo "========================================="
}

case "${1:-}" in
    remove) do_remove ;;
    "")     do_install ;;
    *)      log_error "未知参数: $1  (支持: remove)"; exit 1 ;;
esac
