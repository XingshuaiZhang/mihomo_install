#!/usr/bin/env bash
# Shared interpreter selection. This file only defines functions when sourced.
mihomo_venv_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/mihomo_install/venv"
}

mihomo_python() {
  local candidate
  local -a candidates=()
  if [[ -n "${MIHOMO_PYTHON:-}" ]]; then
    candidates=("$MIHOMO_PYTHON")
  else
    candidates=("$(mihomo_venv_dir)/bin/python" python3)
  fi
  for candidate in "${candidates[@]}"; do
    if "$candidate" -c 'import sys, yaml; assert sys.version_info >= (3, 8); print(sys.executable)' 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
