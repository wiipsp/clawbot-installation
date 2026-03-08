#!/bin/bash
# Install Playwright (Python package + Chromium browser) on OpenCloudOS 8
# Default version: 1.56.0  |  Browser download: cdn.npmmirror.com (淘宝)
# Idempotent — safe to run multiple times
#
# Usage:
#   sudo bash 05_playwright.sh                           # install (default ver 1.56.0, chromium)
#   sudo bash 05_playwright.sh --venv /root/copaw-venv   # install into specific venv
#   sudo bash 05_playwright.sh --ver 1.57.0              # override version
#   sudo bash 05_playwright.sh --browser firefox         # install firefox instead
#   sudo bash 05_playwright.sh remove                    # remove browsers + pip package
#   sudo bash 05_playwright.sh remove --venv /path       # remove from specific venv

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && { log_error "请以 root 权限运行"; exit 1; }

# =========================================
# Parse arguments
# =========================================
SUBCMD=""
VENV_PATH=""
PLAYWRIGHT_VER="1.56.0"   # default pinned version
BROWSER="chromium"

while [[ $# -gt 0 ]]; do
    case "$1" in
        remove)    SUBCMD="remove"; shift ;;
        --venv)    VENV_PATH="$2"; shift 2 ;;
        --ver)     PLAYWRIGHT_VER="$2"; shift 2 ;;
        --browser) BROWSER="$2"; shift 2 ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

# Determine pip / playwright commands based on venv
if [ -n "$VENV_PATH" ]; then
    [ ! -d "$VENV_PATH" ] && { log_error "虚拟环境不存在: $VENV_PATH"; exit 1; }
    source "$VENV_PATH/bin/activate"
    PIP_CMD="pip"
    PW_CMD="playwright"
else
    command -v python3.12 >/dev/null 2>&1 || { log_error "未找到 python3.12，先运行 02_python312.sh"; exit 1; }
    PIP_CMD="python3.12 -m pip"
    PW_CMD="python3.12 -m playwright"
fi

# =========================================
# Helper: check browser binary installed
# =========================================
_browser_installed() {
    local b="${1:-chromium}"
    [ -d "/root/.cache/ms-playwright" ] || return 1
    local dirs
    dirs=$(find /root/.cache/ms-playwright -maxdepth 1 -type d -name "${b}-*" 2>/dev/null || true)
    [ -z "$dirs" ] && return 1
    for d in $dirs; do
        [ -f "$d/chrome-linux/chrome" ] && return 0
        [ -f "$d/firefox/firefox" ]     && return 0
        [ -f "$d/webkit/pw_run" ]        && return 0
    done
    return 1
}

# =========================================
# remove
# =========================================
do_remove() {
    log_warning "将删除：Playwright Python 包 + 浏览器缓存 (~/.cache/ms-playwright)"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    # Remove Python pip package
    $PIP_CMD uninstall -y playwright 2>/dev/null || true
    log_success "Playwright Python 包已删除"

    # Remove npm global package (if exists)
    if command -v npm >/dev/null 2>&1; then
        if npm list -g playwright --depth=0 2>/dev/null | grep -q playwright; then
            log_info "检测到 npm 全局 playwright，正在卸载..."
            npm uninstall -g playwright 2>/dev/null || true
            log_success "npm 全局 playwright 已删除"
        else
            log_info "npm 全局未安装 playwright，跳过"
        fi
    fi

    read -p "同时删除浏览器缓存 /root/.cache/ms-playwright？ (y/N) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf /root/.cache/ms-playwright \
        && log_success "浏览器缓存已删除"

    log_success "Playwright 已删除"
    exit 0
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    echo "========================================="
    echo "Playwright Setup (OpenCloudOS 8)"
    echo "Version: $PLAYWRIGHT_VER  |  Browser: $BROWSER"
    echo "Download mirror: cdn.npmmirror.com"
    [ -n "$VENV_PATH" ] && echo "Venv: $VENV_PATH"
    echo "========================================="

    # --- 1. System browser dependencies ---
    log_info "[1/4] 检查系统依赖..."
    BROWSER_DEPS=(
        libX11 libXcomposite libXdamage libXext libXfixes libXrandr
        libXrender libXtst pango atk gtk3 cups-libs nss alsa-lib
        libxcb libXcursor libXi libXxf86vm libdrm mesa-libGL libgbm
        libxkbcommon fontconfig freetype
    )
    MISSING_DEPS=()
    for dep in "${BROWSER_DEPS[@]}"; do
        rpm -q "$dep" >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
    done
    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        log_info "安装缺失依赖: ${MISSING_DEPS[*]}"
        dnf install -y "${MISSING_DEPS[@]}" 2>/dev/null || \
            log_warning "部分依赖安装失败，不影响后续"
    else
        log_success "系统依赖已就绪"
    fi

    # --- 2. Playwright Python package (pinned version) ---
    log_info "[2/4] 检查 Playwright Python 包 (目标版本: $PLAYWRIGHT_VER)..."
    CURRENT_VER=$($PIP_CMD show playwright 2>/dev/null | awk '/^Version:/{print $2}')
    if [ "$CURRENT_VER" = "$PLAYWRIGHT_VER" ]; then
        log_success "Playwright $PLAYWRIGHT_VER 已安装"
    else
        [ -n "$CURRENT_VER" ] \
            && log_info "版本变更: $CURRENT_VER -> $PLAYWRIGHT_VER" \
            || log_info "安装 Playwright $PLAYWRIGHT_VER..."
        $PIP_CMD install --upgrade "playwright==$PLAYWRIGHT_VER"
        log_success "Playwright $PLAYWRIGHT_VER 安装完成"
    fi

    # --- 3. Browser binary ---
    log_info "[3/4] 检查 $BROWSER 浏览器..."
    if _browser_installed "$BROWSER"; then
        BDIR=$(ls -d /root/.cache/ms-playwright/${BROWSER}-* 2>/dev/null | head -1)
        BVER=$(basename "$BDIR" | cut -d'-' -f2)
        log_success "$BROWSER 已安装 (版本: $BVER)"
    else
        log_info "$BROWSER 未安装，开始下载..."

        _try_install() {
            # 1st: npmmirror (国内首选)
            log_info "尝试 npmmirror 镜像..."
            export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"
            $PW_CMD install "$BROWSER" && { log_success "npmmirror 安装成功"; return 0; }

            # 2nd: official CDN
            log_warning "npmmirror 失败，尝试官方 CDN..."
            export PLAYWRIGHT_DOWNLOAD_HOST="https://playwright.azureedge.net"
            $PW_CMD install "$BROWSER" && { log_success "官方 CDN 安装成功"; return 0; }

            # 3rd: --with-deps
            log_warning "尝试 --with-deps..."
            unset PLAYWRIGHT_DOWNLOAD_HOST
            $PW_CMD install --with-deps "$BROWSER" && { log_success "--with-deps 成功"; return 0; }

            return 1
        }

        if _try_install; then
            if _browser_installed "$BROWSER"; then
                BDIR=$(ls -d /root/.cache/ms-playwright/${BROWSER}-* 2>/dev/null | head -1)
                log_success "验证成功: $(basename "$BDIR")"
            else
                log_warning "安装命令成功但验证失败，请手动检查"
            fi
        else
            log_error "所有安装方法失败，请手动运行:"
            log_error "  export PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright"
            log_error "  $PW_CMD install $BROWSER"
            exit 1
        fi
    fi

    # --- 4. Persist env vars ---
    log_info "[4/4] 写入环境变量..."
    # Write to venv activate if specified
    if [ -n "$VENV_PATH" ] && [ -f "$VENV_PATH/bin/activate" ]; then
        if ! grep -q "PLAYWRIGHT_DOWNLOAD_HOST" "$VENV_PATH/bin/activate"; then
            cat >> "$VENV_PATH/bin/activate" << 'ENVEOF'
export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"
ENVEOF
            log_success "环境变量已写入 $VENV_PATH/bin/activate"
        else
            log_success "venv 环境变量已存在"
        fi
    fi
    # Ensure global mirror file has it
    MIRROR_FILE="/etc/profile.d/clawbot_mirrors.sh"
    if [ -f "$MIRROR_FILE" ] && ! grep -q "PLAYWRIGHT_DOWNLOAD_HOST" "$MIRROR_FILE"; then
        echo 'export PLAYWRIGHT_DOWNLOAD_HOST="https://cdn.npmmirror.com/binaries/playwright"' >> "$MIRROR_FILE"
        log_success "全局镜像配置已更新"
    fi

    echo ""
    log_success "========================================="
    log_success "Playwright 安装完成！"
    log_success "========================================="
    echo "  Python 包:  $($PIP_CMD show playwright 2>/dev/null | awk '/^Version:/{print $2}')"
    if _browser_installed "$BROWSER"; then
        BDIR=$(ls -d /root/.cache/ms-playwright/${BROWSER}-* 2>/dev/null | head -1)
        echo "  $BROWSER: 已安装 ($(du -sh "$BDIR" 2>/dev/null | cut -f1))"
    fi
    echo "  下载镜像:   cdn.npmmirror.com"
    echo "========================================="
}

case "$SUBCMD" in
    remove) do_remove ;;
    "")     do_install ;;
esac
