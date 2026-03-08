#!/bin/bash
# One-click base environment setup for a fresh OpenCloudOS 8 server
# Runs base/ scripts in order based on flags provided.
#
# Usage:
#   sudo bash setup_all.sh                         # system base + Node.js LTS (minimum)
#   sudo bash setup_all.sh --with-python           # + Python 3.12
#   sudo bash setup_all.sh --with-docker           # + Docker CE
#   sudo bash setup_all.sh --with-playwright       # + Playwright (requires --with-python)
#   sudo bash setup_all.sh --with-clash            # + Mihomo (Clash) 代理客户端
#   sudo bash setup_all.sh --node-v22              # Node.js 22 instead of LTS (for OpenClaw)
#
# Full example for CoPaw server:
#   sudo bash setup_all.sh --with-python --with-playwright
#
# Full example for OpenClaw server (with proxy):
#   sudo bash setup_all.sh --node-v22 --with-clash
#
# Full example for mixSearch server:
#   sudo bash setup_all.sh --with-docker

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WITH_PYTHON=0
WITH_DOCKER=0
WITH_PLAYWRIGHT=0
WITH_CLASH=0
NODE_ARG="--lts"

for arg in "$@"; do
    case "$arg" in
        --with-python)     WITH_PYTHON=1 ;;
        --with-docker)     WITH_DOCKER=1 ;;
        --with-playwright) WITH_PLAYWRIGHT=1; WITH_PYTHON=1 ;;  # playwright needs python
        --with-clash)      WITH_CLASH=1 ;;
        --node-v22)        NODE_ARG="--v22" ;;
        --node-lts)        NODE_ARG="--lts" ;;
        --help|-h)
            sed -n '2,21p' "$0"
            exit 0 ;;
        *)
            echo "未知参数: $arg"; exit 1 ;;
    esac
done

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Clawbot Base Environment Setup${NC}"
echo -e "${GREEN}  OpenCloudOS 8 | Mirror: Aliyun + npmmirror${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "安装计划："
echo "  [必须] 01 系统基础包 + 镜像配置"
echo "  [必须] 03 Node.js ($NODE_ARG)"
[ "$WITH_PYTHON" -eq 1 ]     && echo "  [选择] 02 Python 3.12"
[ "$WITH_DOCKER" -eq 1 ]     && echo "  [选择] 04 Docker CE"
[ "$WITH_PLAYWRIGHT" -eq 1 ] && echo "  [选择] 05 Playwright"
[ "$WITH_CLASH" -eq 1 ]      && echo "  [选择] 06 Mihomo (Clash) 代理"
echo ""

# Step 1: System base (always)
echo -e "${YELLOW}[1/5] 系统基础包 + 镜像配置${NC}"
bash "$SCRIPT_DIR/01_system_base.sh"

# Step 2: Python 3.12
if [ "$WITH_PYTHON" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}[2/5] Python 3.12${NC}"
    bash "$SCRIPT_DIR/02_python312.sh"
else
    echo -e "${YELLOW}[2/5] Python 3.12 — 跳过 (使用 --with-python 启用)${NC}"
fi

# Step 3: Node.js (always)
echo ""
echo -e "${YELLOW}[3/5] Node.js ($NODE_ARG)${NC}"
bash "$SCRIPT_DIR/03_nodejs.sh" "$NODE_ARG"

# Step 4: Docker CE
if [ "$WITH_DOCKER" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}[4/5] Docker CE${NC}"
    bash "$SCRIPT_DIR/04_docker.sh"
else
    echo -e "${YELLOW}[4/5] Docker CE — 跳过 (使用 --with-docker 启用)${NC}"
fi

# Step 5: Playwright
if [ "$WITH_PLAYWRIGHT" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}[5/5] Playwright${NC}"
    bash "$SCRIPT_DIR/05_playwright.sh"
else
    echo -e "${YELLOW}[5/5] Playwright — 跳过 (使用 --with-playwright 启用)${NC}"
fi

# Step 6: Mihomo (Clash)
echo ""
if [ "$WITH_CLASH" -eq 1 ]; then
    echo -e "${YELLOW}[6/6] Mihomo (Clash) 代理${NC}"
    bash "$SCRIPT_DIR/06_clash.sh"
else
    echo -e "${YELLOW}[6/6] Mihomo (Clash) — 跳过 (使用 --with-clash 启用)${NC}"
fi

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  基础环境安装完成！${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "下一步："
echo "  安装 CoPaw:      bash ../coPaw/install_copaw.sh"
echo "  安装 OpenClaw:   bash ../openClaw/install_openclaw.sh"
echo "  安装 mixSearch:  bash ../mixSearch/deploy/scripts/install_searxng_tavily.sh"
echo ""
echo "快速一键命令参考："
echo "  # CoPaw 服务器"
echo "  sudo bash setup_all.sh --with-python --with-playwright"
echo "  sudo bash ../coPaw/install_copaw.sh"
echo ""
echo "  # OpenClaw 服务器（含代理，解决 Claude/OpenAI 地区限制）"
echo "  sudo bash setup_all.sh --node-v22 --with-clash"
echo "  sudo bash ../openClaw/install_openclaw.sh"
echo "  sudo bash 06_clash.sh update-sub '<订阅链接>'"
echo "  sudo bash 06_clash.sh inject-openclaw"
echo ""
echo "  # OpenClaw 服务器（无代理）"
echo "  sudo bash setup_all.sh --node-v22"
echo "  sudo bash ../openClaw/install_openclaw.sh"
echo ""
echo "  # mixSearch 服务器"
echo "  sudo bash setup_all.sh --with-docker"
echo "  sudo bash ../mixSearch/deploy/scripts/install_searxng_tavily.sh"
