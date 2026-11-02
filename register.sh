#!/usr/bin/env bash
# 注册 mihomo 快捷命令到 ~/.bashrc

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }

BASHRC="$HOME/.bashrc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/tools/mihomo}"
ensure_entry() {
  local marker="$1"
  local content="$2"

  "${MIHOMO_PYTHON:-python3}" - "$BASHRC" "$marker" "$content" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
marker, content = sys.argv[2:]
original = path.read_text() if path.exists() else ''
lines = original.splitlines()
if marker in lines:
    index = lines.index(marker)
    lines[index:index + 2] = [marker, content]
else:
    lines.extend(['', marker, content])
updated = '\n'.join(lines) + '\n'
if updated == original:
    sys.exit(1)
path.write_text(updated)
PY
}

added=false
ensure_entry "# mihomo quick command" "mihomo() { INSTALL_DIR=$(printf %q "$INSTALL_DIR") source $(printf %q "$SCRIPT_DIR/quick_start.sh"); }" && added=true || true
for entry in nodes upgrade residential; do
  shortcut_command="INSTALL_DIR=$(printf %q "$INSTALL_DIR") bash $(printf %q "$SCRIPT_DIR/$entry.sh")"
  ensure_entry "# mihomo $entry command" "alias mihomo-$entry=$(printf %q "$shortcut_command")" && added=true || true
done

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
echo "  5. 输入: mihomo-upgrade"
echo "  6. 输入: mihomo-residential status"
