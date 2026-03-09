#!/bin/bash
# Check installation status of all base/ components
# No root required for read-only checks
# Optionally pass --venv /path to also check inside a specific virtualenv
#
# Usage:
#   bash check_all.sh                        # check everything
#   bash check_all.sh --venv /root/copaw-venv  # also check venv internals

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[MISS]${NC}  $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC}  $1"; }

FAIL_COUNT=0
VENV_PATH=""
[ "${1:-}" = "--venv" ] && VENV_PATH="$2"

NVM_DIR="${NVM_DIR:-/root/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" 2>/dev/null || true

sep() { echo ""; echo -e "${BLUE}── $1 ──────────────────────────────────${NC}"; }

# =========================================
# 01 System Base
# =========================================
sep "01 · System Base"

for pkg in gcc gcc-c++ make git curl wget openssl sqlite; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        ok "$pkg  $(rpm -q --qf '%{VERSION}' $pkg 2>/dev/null)"
    else
        fail "$pkg  (未安装)"
    fi
done

if [ -f /etc/profile.d/clawbot_mirrors.sh ]; then
    ok "全局镜像配置  /etc/profile.d/clawbot_mirrors.sh"
else
    fail "全局镜像配置  未找到 /etc/profile.d/clawbot_mirrors.sh"
fi

if [ -f /root/.pip/pip.conf ] && grep -q "aliyun" /root/.pip/pip.conf 2>/dev/null; then
    ok "pip 镜像  $(grep index-url /root/.pip/pip.conf | awk '{print $3}')"
else
    warn "pip.conf 未配置或不含阿里云镜像"
fi

# =========================================
# 02 Python 3.12
# =========================================
sep "02 · Python 3.12"

if command -v python3.12 >/dev/null 2>&1; then
    ok "python3.12  $(python3.12 --version 2>&1)"
    if python3.12 -m pip --version >/dev/null 2>&1; then
        ok "pip3.12  $(python3.12 -m pip --version)"
    else
        fail "pip3.12  未找到"
    fi
else
    fail "python3.12  未安装"
fi

# =========================================
# 03 Node.js / nvm
# =========================================
sep "03 · Node.js / nvm"

if [ -d "$NVM_DIR" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
    ok "nvm  已安装 ($NVM_DIR)"
else
    fail "nvm  未安装"
fi

if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node --version)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)
    ok "node  $NODE_VER"
    if [ "$NODE_MAJOR" -ge 22 ]; then
        info "  → Node $NODE_VER 满足 OpenClaw 要求 (>=22)"
    else
        info "  → 如需安装 OpenClaw，需要 Node >=22 (当前 $NODE_VER)"
    fi
else
    fail "node  未安装"
fi

if command -v npm >/dev/null 2>&1; then
    ok "npm  $(npm --version)"
    NPM_REG=$(npm config get registry 2>/dev/null || echo "未知")
    if echo "$NPM_REG" | grep -q "npmmirror"; then
        ok "npm registry  $NPM_REG"
    else
        warn "npm registry  $NPM_REG  (预期 registry.npmmirror.com)"
    fi
else
    fail "npm  未安装"
fi

# =========================================
# 04 Docker
# =========================================
sep "04 · Docker"

if command -v docker >/dev/null 2>&1; then
    ok "docker  $(docker --version)"
    if docker compose version >/dev/null 2>&1; then
        ok "docker compose  $(docker compose version)"
    else
        warn "docker compose  不可用"
    fi
    if systemctl is-active docker >/dev/null 2>&1; then
        ok "dockerd  running"
    else
        warn "dockerd  not running"
    fi
    if [ -f /etc/docker/daemon.json ] && grep -q "mirror" /etc/docker/daemon.json 2>/dev/null; then
        ok "daemon.json  镜像加速已配置"
    else
        warn "daemon.json  未配置镜像加速"
    fi
else
    info "docker  未安装 (非必须，hybrid-search 需要)"
fi

# =========================================
# 05 Playwright
# =========================================
sep "05 · Playwright"

PW_CHECKED=0
# Check inside venv if specified
if [ -n "$VENV_PATH" ] && [ -d "$VENV_PATH" ]; then
    source "$VENV_PATH/bin/activate" 2>/dev/null || true
    PW_CHECKED=1
fi

if command -v playwright >/dev/null 2>&1 || python3.12 -m playwright --version >/dev/null 2>&1; then
    PW_VER=$(pip show playwright 2>/dev/null | awk '/^Version:/{print $2}')
    ok "playwright  $PW_VER"
    if [ "$PW_VER" = "1.56.0" ]; then
        ok "  → 版本匹配推荐版本 1.56.0"
    else
        warn "  → 推荐版本 1.56.0，当前 $PW_VER"
    fi
else
    info "playwright  未安装 (仅 CoPaw 需要)"
fi

if [ -d "/root/.cache/ms-playwright" ] && [ -n "$(ls /root/.cache/ms-playwright 2>/dev/null)" ]; then
    for bdir in /root/.cache/ms-playwright/*/; do
        [ -d "$bdir" ] || continue
        BNAME=$(basename "$bdir")
        BSIZE=$(du -sh "$bdir" 2>/dev/null | cut -f1)
        if [ -f "$bdir/chrome-linux/chrome" ] || [ -f "$bdir/firefox/firefox" ] || [ -f "$bdir/webkit/pw_run" ]; then
            ok "browser  $BNAME ($BSIZE)"
        else
            warn "browser  $BNAME — 目录存在但可执行文件缺失"
        fi
    done
else
    info "Playwright 浏览器  未安装 (仅 CoPaw 需要)"
fi

# =========================================
# 06 Mihomo (Clash)
# =========================================
sep "06 · Mihomo (Clash) 代理"

if command -v mihomo >/dev/null 2>&1; then
    ok "mihomo  $(mihomo -v 2>/dev/null | head -1)"
else
    info "mihomo  未安装 (可选，解决 Claude/OpenAI 地区限制)"
fi

if systemctl is-active mihomo >/dev/null 2>&1; then
    ok "mihomo.service  running"
    # Test HTTP proxy
    if curl -x http://127.0.0.1:7890 -s --max-time 5 -o /dev/null -w '%{http_code}' \
        https://openrouter.ai 2>/dev/null | grep -q "200\|301\|302"; then
        ok "HTTP 代理 127.0.0.1:7890  可用（OpenRouter 可访问）"
    else
        warn "HTTP 代理 127.0.0.1:7890  进程运行但代理测试未通过（请检查订阅配置）"
    fi
elif command -v mihomo >/dev/null 2>&1; then
    warn "mihomo.service  not running"
fi

if [ -f /etc/mihomo/config.yaml ] && [ -s /etc/mihomo/config.yaml ]; then
    PROXY_COUNT=$(grep -c '{"name":' /etc/mihomo/config.yaml 2>/dev/null || echo 0)
    ok "config.yaml  已存在（节点数约 ${PROXY_COUNT}）"
else
    info "config.yaml  未配置（运行: sudo bash 06_clash.sh update-sub '<URL>'）"
fi

# Check if openclaw has proxy injected
OPENCLAW_OVERRIDE="$HOME/.config/systemd/user/openclaw-gateway.service.d/proxy.conf"
if [ -f "$OPENCLAW_OVERRIDE" ] && grep -q "HTTPS_PROXY" "$OPENCLAW_OVERRIDE" 2>/dev/null; then
    ok "OpenClaw 代理注入  已配置 ($OPENCLAW_OVERRIDE)"
else
    info "OpenClaw 代理注入  未配置（运行: sudo bash 06_clash.sh inject-openclaw）"
fi

# =========================================
# Venv deep check (if --venv passed)
# =========================================
if [ -n "$VENV_PATH" ] && [ -d "$VENV_PATH" ]; then
    sep "Venv · $VENV_PATH"
    source "$VENV_PATH/bin/activate" 2>/dev/null || true

    for pkg in copaw agentscope playwright pysqlite3 uv; do
        if pip show "$pkg" >/dev/null 2>&1; then
            VER=$(pip show "$pkg" | awk '/^Version:/{print $2}')
            ok "$pkg  $VER"
        else
            info "$pkg  未安装"
        fi
    done

    PY_SQLITE=$(python -c "import sqlite3; print(sqlite3.sqlite_version)" 2>/dev/null || echo "未知")
    if [[ "$PY_SQLITE" > "3.35.0" ]] || [[ "$PY_SQLITE" = "3.35.0" ]]; then
        ok "SQLite (Python内)  $PY_SQLITE  >= 3.35.0 ✓"
    else
        warn "SQLite (Python内)  $PY_SQLITE  < 3.35.0，可能影响 ChromaDB"
    fi

    if grep -q "pysqlite3" "$VENV_PATH/../$(python -c 'import site;print(site.getsitepackages()[0])' 2>/dev/null | xargs basename 2>/dev/null || echo "")/chromadb/__init__.py" 2>/dev/null; then
        ok "ChromaDB 补丁  已应用"
    else
        info "ChromaDB 补丁  未检测到（chromadb 未安装或未打补丁）"
    fi
fi

# =========================================
# Summary
# =========================================
echo ""
echo -e "${BLUE}══════════════════════════════════════════${NC}"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}  所有检查通过！${NC}"
else
    echo -e "${RED}  ${FAIL_COUNT} 项检查未通过，请查看上方 [MISS] 条目${NC}"
fi
echo -e "${BLUE}══════════════════════════════════════════${NC}"
echo ""
echo "修复建议："
echo "  [MISS] gcc/make 等   → sudo bash 01_system_base.sh"
echo "  [MISS] python3.12    → sudo bash 02_python312.sh"
echo "  [MISS] node/nvm      → sudo bash 03_nodejs.sh"
echo "  [MISS] docker        → sudo bash 04_docker.sh"
echo "  [MISS] playwright    → sudo bash 05_playwright.sh [--venv /path]"
echo "  [MISS] mihomo/clash  → sudo bash 06_clash.sh"
echo ""
