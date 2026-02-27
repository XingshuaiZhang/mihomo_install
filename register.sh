#!/usr/bin/env bash
# 注册 mihomo 快捷命令到 ~/.bashrc

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }

BASHRC="$HOME/.bashrc"
MARKER="# mihomo quick command"
FUNCTION='mihomo() { source ~/tools/mihomo_install/quick_start.sh; }'

# 检查是否已注册
if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
  info "mihomo 命令已注册"
  echo ""
  echo "使用方法：在新终端中输入 'mihomo' 即可启动代理"
  exit 0
fi

# 添加到 bashrc
echo "" >> "$BASHRC"
echo "$MARKER" >> "$BASHRC"
echo "$FUNCTION" >> "$BASHRC"

info "mihomo 命令注册成功！"
echo ""
echo "使用方法："
echo "  1. 执行: source ~/.bashrc"
echo "  2. 或重新打开终端"
echo "  3. 输入: mihomo"
