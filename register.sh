#!/usr/bin/env bash
# 注册 mihomo 快捷命令到 ~/.bashrc

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }

BASHRC="$HOME/.bashrc"
ensure_entry() {
  local marker="$1"
  local content="$2"

  if grep -qF "$marker" "$BASHRC" 2>/dev/null; then
    return 1
  fi

  echo "" >> "$BASHRC"
  echo "$marker" >> "$BASHRC"
  echo "$content" >> "$BASHRC"
  return 0
}

added=false
ensure_entry "# mihomo quick command" 'mihomo() { source ~/tools/mihomo_install/quick_start.sh; }' && added=true || true
ensure_entry "# mihomo nodes command" "alias mihomo-nodes='bash ~/tools/mihomo_install/nodes.sh'" && added=true || true

if $added; then
  info "mihomo 命令注册成功！"
else
  info "mihomo 命令已注册"
fi
echo ""
echo "使用方法："
echo "  1. 执行: source ~/.bashrc"
echo "  2. 或重新打开终端"
echo "  3. 输入: mihomo"
echo "  4. 输入: mihomo-nodes"
