#!/usr/bin/env bash
# Install residential-mode dependencies inside the user's own directory.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/python_env.sh"

if RESIDENTIAL_PYTHON="$(mihomo_python)"; then
  echo "Python / PyYAML 已可用，无需安装：$RESIDENTIAL_PYTHON"
  exit 0
fi

if [[ -n "${MIHOMO_PYTHON:-}" ]]; then
  echo "指定的 MIHOMO_PYTHON 不可用、低于 3.8 或缺少 PyYAML。" >&2
  echo "可取消该变量后运行本脚本，或指定已有 PyYAML 的 Conda / 虚拟环境解释器。" >&2
  exit 1
fi

command -v python3 >/dev/null || { echo "需要 Python 3.8+；可使用用户目录中的 Miniconda / Python。" >&2; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || { echo "需要 Python 3.8+。" >&2; exit 1; }
RESIDENTIAL_VENV="$(mihomo_venv_dir)"
BOOTSTRAP_TMP="$(mktemp -d)"
trap 'rm -rf "$BOOTSTRAP_TMP"' EXIT

echo "在用户目录准备 Python 环境：$RESIDENTIAL_VENV"
mkdir -p "$(dirname "$RESIDENTIAL_VENV")"
if ! python3 -m venv "$RESIDENTIAL_VENV" >"$BOOTSTRAP_TMP/venv.log" 2>&1; then
  # Ubuntu may ship Python without ensurepip/python3-venv. virtualenv's official
  # version-specific zipapp includes its own seed packages and needs no root.
  command -v curl >/dev/null || { echo "缺少 curl，无法下载用户环境安装工具。" >&2; exit 1; }
  PYTHON_MINOR="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  echo "系统 venv 不可用，使用 PyPA virtualenv 创建用户环境。"
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 \
    "https://bootstrap.pypa.io/virtualenv/${PYTHON_MINOR}/virtualenv.pyz" \
    -o "$BOOTSTRAP_TMP/virtualenv.pyz"
  python3 "$BOOTSTRAP_TMP/virtualenv.pyz" --no-download --no-periodic-update \
    --python "$(command -v python3)" "$RESIDENTIAL_VENV"
fi

PIP_RUNNER=(-m pip)
if ! "$RESIDENTIAL_VENV/bin/python" -m pip --version >/dev/null 2>&1; then
  # Minimal Ubuntu Python 3.8/3.9 may also lack python3-distutils. pip 25.x
  # supports this sysconfig override; it is local to this bootstrap process.
  # https://github.com/pypa/pip/blob/25.0.1/src/pip/_internal/locations/__init__.py
  PIP_RUNNER=(-c 'import runpy, sysconfig; sysconfig._PIP_USE_SYSCONFIG = True; runpy.run_module("pip", run_name="__main__")')
fi
"$RESIDENTIAL_VENV/bin/python" "${PIP_RUNNER[@]}" install --disable-pip-version-check \
  --prefer-binary --retries 2 --timeout 30 'PyYAML>=6,<7'
"$RESIDENTIAL_VENV/bin/python" -c 'import yaml'
echo "依赖已就绪。install.sh / residential.sh 会自动使用此环境，无需 activate。"
