#!/usr/bin/env bash
# 网络连接测试脚本
# 用于测试 mihomo 代理和 GitHub 访问

set -euo pipefail

# Residential installations use an exit check that never retries outside the proxy.
MIHOMO_DIR="${INSTALL_DIR:-${HOME}/tools/mihomo}"
if [[ -f "$MIHOMO_DIR/residential-source.yaml" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec bash "$SCRIPT_DIR/residential.sh" --install-dir "$MIHOMO_DIR" verify "$@"
fi

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*"; }
test_item() { echo -e "${BLUE}[TEST]${NC} $*"; }
success() { echo -e "${GREEN}[ ✓ ]${NC} $*"; }
fail() { echo -e "${RED}[ ✗ ]${NC} $*"; }

# 测试函数
test_url() {
  local url="$1"
  local description="$2"

  test_item "$description"
  if curl -s --connect-timeout 10 --max-time 30 "$url" >/dev/null 2>&1; then
    success "$description - 成功"
    return 0
  else
    fail "$description - 失败"
    return 1
  fi
}

test_proxy_url() {
  local url="$1"
  local description="$2"
  local proxy="$3"

  test_item "$description (via $proxy)"
  if curl -s --connect-timeout 10 --max-time 30 -x "$proxy" "$url" >/dev/null 2>&1; then
    success "$description - 成功"
    return 0
  else
    fail "$description - 失败"
    return 1
  fi
}

echo "========================================="
echo "        网络连接测试工具"
echo "========================================="
echo

# 配置
PROXY_HOST="127.0.0.1"
PROXY_PORT="7890"
HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
SOCKS_PROXY="socks5://${PROXY_HOST}:${PROXY_PORT}"

# 测试直连
info "=== 测试直连 ==="
echo
test_url "https://www.google.com" "Google 访问" || true
test_url "https://www.youtube.com" "YouTube 访问" || true
test_url "https://www.github.com" "GitHub 直连" || true
test_url "https://api.ipify.org" "IP 查询服务" || true
echo

# 检查 mihomo 状态
info "=== 检查 mihomo 状态 ==="
echo
if [[ -d "$MIHOMO_DIR" ]]; then
  if pgrep -f "mihomo -d.*$MIHOMO_DIR" >/dev/null 2>&1; then
    success "Mihomo 正在运行"
  else
    warn "Mihomo 未运行"
    echo "启动方式: $MIHOMO_DIR/run.sh"
  fi
else
  warn "Mihomo 未安装"
fi
echo

# 测试代理
info "=== 测试代理连接 ==="
echo
test_proxy_url "https://www.google.com" "Google 访问" "$HTTP_PROXY" || true
test_proxy_url "https://www.github.com" "GitHub 访问" "$HTTP_PROXY" || true
test_proxy_url "https://api.ipify.org" "IP 查询" "$HTTP_PROXY" || true
echo

# 测试 GitHub 代理
info "=== 测试 GitHub 加速代理 ==="
echo
GH_PROXIES=(
  "https://ghproxy.net/"
  "https://gh-proxy.com/"
  "https://gh.api.99988866.xyz/"
  "https://gh-proxy.liuzhicong.com/"
  "https://mirror.ghproxy.com/"
)

WORKING_PROXIES=()
for proxy in "${GH_PROXIES[@]}"; do
  if test_url "${proxy}https://github.com" "GitHub 代理: $proxy"; then
    WORKING_PROXIES+=("$proxy")
  fi
done

if [[ ${#WORKING_PROXIES[@]} -gt 0 ]]; then
  echo
  info "可用的 GitHub 代理："
  for proxy in "${WORKING_PROXIES[@]}"; do
    echo "  - $proxy"
  done
else
  echo
  warn "没有找到可用的 GitHub 代理"
fi
echo

# 获取当前 IP
info "=== 当前 IP 信息 ==="
echo
test_item "获取当前 IP"
CURRENT_IP=$(curl -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "未知")
echo "当前 IP: $CURRENT_IP"

if pgrep -f "mihomo -d.*$MIHOMO_DIR" >/dev/null 2>&1; then
  PROXY_IP=$(curl -s --connect-timeout 10 -x "$HTTP_PROXY" https://api.ipify.org 2>/dev/null || echo "未知")
  echo "代理 IP: $PROXY_IP"
fi
echo

echo "========================================="
info "测试完成"
echo "========================================="

# 提供操作建议
echo
info "操作建议："
echo "1. 如果 Mihomo 未运行，执行: $MIHOMO_DIR/run.sh"
echo "2. 如果代理不工作，检查日志: tail -f $MIHOMO_DIR/run/mihomo.log"
echo "3. 如果 GitHub 直连失败，重新运行安装脚本并选择可用的代理"
echo
