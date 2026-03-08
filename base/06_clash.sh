#!/bin/bash
# Install Mihomo (Clash Meta) proxy client on OpenCloudOS 8
# Downloads binary via gh.llkk.cc mirror (GitHub proxy for GFW environments)
# Manages config via subscription URL, runs as systemd service
#
# Usage:
#   sudo bash 06_clash.sh                        # install (idempotent)
#   sudo bash 06_clash.sh remove                 # uninstall
#   sudo bash 06_clash.sh update-sub <URL>       # update subscription config

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && { log_error "请以 root 权限运行"; exit 1; }

MIHOMO_VER="v1.19.20"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
GH_MIRROR="https://gh.llkk.cc"
GH_MIRROR_FALLBACK="https://ghfast.top"

# =========================================
# remove
# =========================================
do_remove() {
    log_warning "将删除：mihomo 二进制、配置目录 /etc/mihomo、systemd 服务"
    read -p "确认继续？ (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    systemctl stop mihomo 2>/dev/null || true
    systemctl disable mihomo 2>/dev/null || true
    rm -f "$MIHOMO_BIN"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    log_warning "配置目录 $MIHOMO_DIR 已保留（含订阅配置），如需删除请手动执行: rm -rf $MIHOMO_DIR"
    log_success "Mihomo 已卸载"
    exit 0
}

# =========================================
# update-sub: 更新订阅配置
# =========================================
do_update_sub() {
    local url="$1"
    [ -z "$url" ] && { log_error "请提供订阅链接: sudo bash 06_clash.sh update-sub <URL>"; exit 1; }
    log_info "下载订阅配置..."
    curl -fsSL "$url" -o "$MIHOMO_DIR/config.yaml"
    # 订阅的 external-controller 改为只监听本地
    sed -i "s|external-controller: '0.0.0.0:9090'|external-controller: '127.0.0.1:9090'|g" \
        "$MIHOMO_DIR/config.yaml" 2>/dev/null || true
    log_success "订阅配置更新完成"
    systemctl restart mihomo && log_success "Mihomo 已重启"
    exit 0
}

# =========================================
# install (idempotent)
# =========================================
do_install() {
    echo "========================================="
    echo "Mihomo (Clash Meta) Setup (OpenCloudOS 8)"
    echo "Binary: ${GH_MIRROR} (GitHub 镜像)"
    echo "========================================="

    # --- 1. Download binary ---
    log_info "[1/4] 检查 Mihomo 二进制..."
    if [ -f "$MIHOMO_BIN" ] && "$MIHOMO_BIN" -v 2>/dev/null | grep -q "Mihomo"; then
        log_success "Mihomo 已安装: $($MIHOMO_BIN -v 2>/dev/null | head -1)"
    else
        log_info "下载 Mihomo ${MIHOMO_VER}（通过 GitHub 镜像）..."
        FILENAME="mihomo-linux-amd64-${MIHOMO_VER}.gz"
        ORIG_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/${FILENAME}"

        if curl -fsSL -o /tmp/mihomo.gz "${GH_MIRROR}/${ORIG_URL}" 2>/dev/null; then
            log_success "下载成功（主镜像）"
        elif curl -fsSL -o /tmp/mihomo.gz "${GH_MIRROR_FALLBACK}/${ORIG_URL}" 2>/dev/null; then
            log_success "下载成功（备用镜像）"
        else
            log_error "两个镜像均下载失败，请检查网络后重试"
            exit 1
        fi

        cd /tmp && gunzip -f mihomo.gz
        EXTRACTED=$(ls /tmp/mihomo-linux-amd64-* 2>/dev/null | head -1)
        [ -n "$EXTRACTED" ] && mv "$EXTRACTED" "$MIHOMO_BIN" || mv /tmp/mihomo "$MIHOMO_BIN"
        chmod +x "$MIHOMO_BIN"
        log_success "Mihomo 安装完成: $($MIHOMO_BIN -v 2>/dev/null | head -1)"
    fi

    # --- 2. Config dir + GeoIP DB ---
    log_info "[2/4] 准备配置目录和 GeoIP 数据库..."
    mkdir -p "$MIHOMO_DIR"

    if [ -f "$MIHOMO_DIR/country.mmdb" ] && [ -s "$MIHOMO_DIR/country.mmdb" ]; then
        log_success "country.mmdb 已存在"
    else
        log_info "下载 GeoIP 数据库..."
        MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
        if curl -fsSL "${GH_MIRROR}/${MMDB_URL}" -o "$MIHOMO_DIR/country.mmdb" 2>/dev/null; then
            log_success "country.mmdb 下载完成"
        elif curl -fsSL "${GH_MIRROR_FALLBACK}/${MMDB_URL}" -o "$MIHOMO_DIR/country.mmdb" 2>/dev/null; then
            log_success "country.mmdb 下载完成（备用镜像）"
        else
            log_warning "country.mmdb 下载失败，Mihomo 首次启动时会自动下载"
        fi
    fi

    # --- 3. Subscription config ---
    log_info "[3/4] 检查订阅配置..."
    if [ -f "$MIHOMO_DIR/config.yaml" ] && [ -s "$MIHOMO_DIR/config.yaml" ]; then
        log_success "config.yaml 已存在，跳过（如需更新：sudo bash 06_clash.sh update-sub <URL>）"
    else
        log_warning "未找到 config.yaml"
        echo ""
        echo "  请提供 Clash 订阅链接完成配置，例如："
        echo "    sudo bash 06_clash.sh update-sub 'https://your-sub-url?clash=1'"
        echo ""
        echo "  或手动下载配置到 $MIHOMO_DIR/config.yaml"
        echo ""
        # Create a minimal placeholder so service can start (will fail gracefully)
        cat > "$MIHOMO_DIR/config.yaml" << 'YAML_EOF'
# Placeholder config - replace with your subscription
# Run: sudo bash 06_clash.sh update-sub '<your-subscription-url>'
port: 7890
socks-port: 7891
allow-lan: false
mode: Direct
log-level: info
external-controller: '127.0.0.1:9090'
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
YAML_EOF
        log_warning "已写入占位配置，请尽快更新订阅"
    fi

    # Ensure external-controller only listens locally
    sed -i "s|external-controller: '0.0.0.0:9090'|external-controller: '127.0.0.1:9090'|g" \
        "$MIHOMO_DIR/config.yaml" 2>/dev/null || true

    # --- 4. systemd service ---
    log_info "[4/4] 配置 systemd 服务..."
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Mihomo Proxy Service
After=network.target NetworkManager.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mihomo

    if systemctl is-active mihomo >/dev/null 2>&1; then
        systemctl restart mihomo
        log_success "Mihomo 服务已重启"
    else
        systemctl start mihomo
        log_success "Mihomo 服务已启动"
    fi

    sleep 2
    if systemctl is-active mihomo >/dev/null 2>&1; then
        log_success "Mihomo 运行中"
    else
        log_error "Mihomo 启动失败，查看日志: journalctl -u mihomo -n 30"
        exit 1
    fi

    echo ""
    log_success "========================================="
    log_success "Mihomo 安装完成！"
    log_success "========================================="
    echo "  HTTP 代理:   http://127.0.0.1:7890"
    echo "  SOCKS5 代理: socks5://127.0.0.1:7891"
    echo "  控制面板:    http://127.0.0.1:9090"
    echo "  配置目录:    $MIHOMO_DIR"
    echo ""
    echo "更新订阅:   sudo bash 06_clash.sh update-sub '<URL>'"
    echo "卸载:       sudo bash 06_clash.sh remove"
    echo ""
    echo "给 OpenClaw 配置代理（如需）:"
    echo "  bash 06_clash.sh inject-openclaw"
    echo "========================================="
}

# =========================================
# inject-openclaw: 给 openclaw-gateway 注入代理环境变量
# =========================================
do_inject_openclaw() {
    OVERRIDE_DIR="$HOME/.config/systemd/user/openclaw-gateway.service.d"
    OVERRIDE_FILE="$OVERRIDE_DIR/proxy.conf"

    if [ ! -f "$HOME/.config/systemd/user/openclaw-gateway.service" ]; then
        log_error "未找到 openclaw-gateway.service，请先安装 OpenClaw"
        exit 1
    fi

    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE_FILE" << 'EOF'
[Service]
Environment=HTTPS_PROXY=http://127.0.0.1:7890
Environment=HTTP_PROXY=http://127.0.0.1:7890
Environment=NO_PROXY=localhost,127.0.0.1,::1
EOF

    systemctl --user daemon-reload
    systemctl --user restart openclaw-gateway
    log_success "已为 OpenClaw 注入代理配置，服务已重启"
    exit 0
}

case "${1:-}" in
    remove)      do_remove ;;
    update-sub)  do_update_sub "${2:-}" ;;
    inject-openclaw) do_inject_openclaw ;;
    "")          do_install ;;
    *)           log_error "未知参数: $1  (支持: remove | update-sub <URL> | inject-openclaw)"; exit 1 ;;
esac
