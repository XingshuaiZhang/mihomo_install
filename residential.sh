#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/python_env.sh"
if ! RESIDENTIAL_PYTHON="$(mihomo_python)"; then
  echo "缺少可用的 Python / PyYAML。请先运行：bash \"$SCRIPT_DIR/setup_python.sh\"（无需管理员权限）" >&2
  exit 1
fi
exec "$RESIDENTIAL_PYTHON" "$SCRIPT_DIR/residential.py" "$@"
