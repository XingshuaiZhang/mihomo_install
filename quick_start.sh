#!/usr/bin/env bash
# Mihomo 代理快速启动脚本
# 使用方法：source ~/tools/mihomo_install/quick_start.sh

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 配置
MIHOMO_DIR="${HOME}/tools/mihomo"
MIXED_PORT="7890"

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*"; }

# 检查 mihomo 是否安装
if [[ ! -d "$MIHOMO_DIR" ]]; then
  error "Mihomo 未安装"
  echo "请先运行：cd ~/tools/mihomo_install && bash install.sh"
  return 1
fi

# 检查 mihomo 是否运行
if ! pgrep -f "mihomo -d.*$MIHOMO_DIR" >/dev/null 2>&1; then
  warn "Mihomo 未运行，正在启动..."
  "$MIHOMO_DIR/run.sh"
  sleep 2
fi

# 检查是否成功启动
if pgrep -f "mihomo -d.*$MIHOMO_DIR" >/dev/null 2>&1; then
  info "Mihomo 运行中"
else
  error "Mihomo 启动失败"
  return 1
fi

# 设置代理环境变量
export http_proxy="http://127.0.0.1:${MIXED_PORT}"
export https_proxy="http://127.0.0.1:${MIXED_PORT}"
export all_proxy="socks5://127.0.0.1:${MIXED_PORT}"
export HTTP_PROXY="http://127.0.0.1:${MIXED_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${MIXED_PORT}"
export ALL_PROXY="socks5://127.0.0.1:${MIXED_PORT}"

# 测试连接
if curl -s --connect-timeout 5 https://api.ipify.org >/dev/null 2>&1; then
  IP=$(curl -s --connect-timeout 5 https://api.ipify.org)
  info "代理配置成功！当前 IP: $IP"
  info "yacd: https://yacd.metacubex.one | 端口: 9090"
else
  warn "代理已配置，但连接测试失败"
fi
