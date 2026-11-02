#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESIDENTIAL_INPUT_DIR=""
cleanup_residential_input() {
  if [[ -n "$RESIDENTIAL_INPUT_DIR" ]]; then
    rm -rf -- "$RESIDENTIAL_INPUT_DIR"
    RESIDENTIAL_INPUT_DIR=""
  fi
}
trap cleanup_residential_input EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =========================
# Helpers
# =========================
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"; }

ask_yes_no() {
  local answer
  if ! read -r -p "$1" answer; then
    err "没有读取到输入，安装已中止。" >&2
    return 1
  fi
  case "${answer:-$2}" in
    [Yy]|[Yy][Ee][Ss]) printf 'Y\n' ;;
    [Nn]|[Nn][Oo]) printf 'N\n' ;;
    *) err "请输入 y 或 n。" >&2; return 1 ;;
  esac
}

prepare_python() {
  source "$SCRIPT_DIR/python_env.sh"
  if ! RESIDENTIAL_PYTHON="$(mihomo_python)"; then
    bash "$SCRIPT_DIR/setup_python.sh" || die "用户目录 Python 环境准备失败，请检查上方提示后重试。"
    RESIDENTIAL_PYTHON="$(mihomo_python)" || die "无法找到带 PyYAML 的 Python。"
  fi
  export MIHOMO_PYTHON="$RESIDENTIAL_PYTHON"
}

escape_yaml_double_quotes() { sed 's/"/\\"/g'; }

rand_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24
  else date +%s%N | sha256sum | awk '{print $1}' | head -c 48
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "不支持的架构：$(uname -m)（仅支持 amd64/arm64/armv7）" ;;
  esac
}

# =========================
# Curl wrappers (stable)
# =========================
curl_get() {
  local url="$1" out="$2"
  curl -fL \
    --retry 8 --retry-delay 2 --retry-connrefused \
    --connect-timeout 10 --max-time 1200 \
    -o "$out" "$url"
}

curl_text() {
  local url="$1"
  curl -fsSL \
    --retry 6 --retry-delay 2 --retry-connrefused \
    --connect-timeout 8 --max-time 90 \
    "$url"
}

curl_head_location() {
  # print final "Location:" if exists
  local url="$1"
  curl -fsSIL \
    --retry 6 --retry-delay 2 --retry-connrefused \
    --connect-timeout 8 --max-time 60 \
    "$url" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tail -n 1 | tr -d '\r'
}

# =========================
# GitHub proxy handling
# =========================
# 更新的代理列表（2025年可用）
DEFAULT_PROXY_CANDIDATES=(
  "https://ghproxy.net/"
  "https://gh-proxy.com/"
  "https://gh.api.99988866.xyz/"
  "https://gh-proxy.liuzhicong.com/"
  "https://github.moeyy.xyz/"
  "https://mirror.ghproxy.com/"
  "https://ghproxy.com/"
  "https://ghfast.top/"
  "https://gh.llkk.cc/"
  "https://gh.cker.xyz/"
)

apply_gh_proxy() {
  local url="$1"
  if [[ -n "${GH_PROXY:-}" ]]; then
    [[ "$url" == "${GH_PROXY}"* ]] && echo "$url" || echo "${GH_PROXY}${url}"
  else
    echo "$url"
  fi
}

probe_url() {
  local url="$1"
  curl -fsSL --connect-timeout 4 --max-time 8 "$url" >/dev/null 2>&1
}

pick_working_proxy() {
  local test="https://github.com/MetaCubeX/mihomo/releases/latest"
  for p in "${DEFAULT_PROXY_CANDIDATES[@]}"; do
    if probe_url "${p}${test}"; then echo "$p"; return 0; fi
  done
  return 1
}

# =========================
# Robust GitHub asset resolver (NO API)
# =========================
# 1) Try: /releases/latest/download/<asset>  -> follow redirect via HEAD Location (fast & stable)
# 2) Fallback: fetch releases/latest HTML and parse href download links
resolve_mihomo_asset_url() {
  local repo="MetaCubeX/mihomo"
  local asset_name="$1" # e.g. mihomo-linux-amd64-compatible.gz (latest alias is not provided, so we use redirect trick below)

  # --- Approach 1: HTML parse to find the exact latest versioned asset name ---
  # We cannot know the version in advance, so we parse releases/latest page and pick the first matching .gz link.
  local latest_page="https://github.com/${repo}/releases/latest"
  local page_url
  page_url="$(apply_gh_proxy "$latest_page")"

  info "拉取 releases/latest 页面用于解析资产链接…（可能需要代理）"
  local html=""
  html="$(curl_text "$page_url" 2>/dev/null || true)"
  [[ -n "$html" ]] || die "无法获取 releases/latest 页面（直连/代理都失败）。请换 GH 代理前缀重试。"

  # Disable errexit for parsing to avoid silent exit on grep no-match
  set +e
  local rel
  rel="$(echo "$html" | grep -Eo "/${repo}/releases/download/[^\"']+mihomo-linux-.*${asset_name}" | head -n 1)"
  set -e

  [[ -n "${rel:-}" ]] || die "解析失败：未在 releases/latest 页面找到匹配资产（${asset_name}）。"

  local url="https://github.com${rel}"
  echo "$url"
}

pick_asset_suffix() {
  # Return a regex-ish suffix to match desired file variants
  # Prefer "compatible" builds if present; accept others as fallback.
  # We'll match "...mihomo-linux-${ARCH}.*\\.gz"
  local arch="$1"
  echo "mihomo-linux-${arch}.*\.gz"
}

# =========================
# Preflight
# =========================
need_cmd curl
need_cmd gzip
need_cmd sed
need_cmd grep
need_cmd awk
need_cmd sha256sum

info "一键安装 / 配置 mihomo：依赖、住宅出口、启动、定时更新和出口验证（无需 sudo）。"
echo

# =========================
# Interactive inputs
# =========================
default_dir="${INSTALL_DIR:-$HOME/tools/mihomo}"
read -r -p "请输入安装目录（默认：${default_dir}）: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$default_dir}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
INSTALL_DIR="$(readlink -m -- "$INSTALL_DIR")"
EXISTING_INSTALL=false
if [[ -e "$INSTALL_DIR/config.yaml" ]]; then
  [[ -x "$INSTALL_DIR/bin/mihomo" ]] || die "已有配置但缺少可执行的 bin/mihomo，请先修复该安装目录。"
  EXISTING_INSTALL=true
  info "检测到已有安装，将复用现有内核、订阅、端口和控制密钥。"
fi

USE_RESIDENTIAL=Y
if [[ -n "${RESIDENTIAL_SETTINGS_FILE:-}" ]]; then
  [[ -f "$RESIDENTIAL_SETTINGS_FILE" ]] || die "住宅配置文件不存在：$RESIDENTIAL_SETTINGS_FILE"
elif [[ -f "$INSTALL_DIR/residential-source.yaml" ]]; then
  info "已有住宅模式配置，将保留住宅出口。按后续提示回车可复用原参数。"
else
  USE_RESIDENTIAL="$(ask_yes_no '是否启用固定住宅 SOCKS5 出口？（Y/n）: ' Y)"
fi
prepare_python

# Collect credentials before downloads; users never need to prepare a JSON file.
if [[ "$USE_RESIDENTIAL" == Y && -z "${RESIDENTIAL_SETTINGS_FILE:-}" ]]; then
  info "先设置住宅出口：粘贴 IP:端口@用户名:密码即可，无需准备配置文件。"
  RESIDENTIAL_INPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-residential.XXXXXXXX")"
  RESIDENTIAL_SETTINGS_FILE="$RESIDENTIAL_INPUT_DIR/settings.json"
  "$RESIDENTIAL_PYTHON" "$SCRIPT_DIR/residential.py" --install-dir "$INSTALL_DIR" \
    collect-settings --output "$RESIDENTIAL_SETTINGS_FILE" || die "住宅参数输入已取消或保存失败。"
  info "住宅参数已接收，接下来配置订阅并安装。"
fi

if [[ "$EXISTING_INSTALL" == false ]]; then

read -r -p "请输入 Clash 订阅链接（可直接粘贴，包含 & 也没问题）: " SUB_URL
[[ -n "${SUB_URL:-}" ]] || die "订阅链接不能为空。"

# 验证订阅链接格式并提取信息
info "解析订阅链接格式..."
if [[ "$SUB_URL" == *"?"* ]]; then
  info "检测到订阅链接包含参数（可能是转换链接）"
fi

# 测试订阅链接是否可访问
info "测试订阅链接可访问性..."
if curl -fsSL --connect-timeout 10 --max-time 30 "$SUB_URL" >/dev/null 2>&1; then
  info "订阅链接可访问"
else
  warn "订阅链接可能无法访问，但继续安装"
fi

read -r -p "代理端口 mixed-port（默认 7890）: " MIXED_PORT
MIXED_PORT="${MIXED_PORT:-7890}"

read -r -p "控制端口 external-controller（默认 9090，仅监听 127.0.0.1）: " CTRL_PORT
CTRL_PORT="${CTRL_PORT:-9090}"

echo
cat <<'EOF'
GitHub 下载超时解决方案：
- 可手动输入 GitHub 加速代理前缀（留空则自动探测常见代理）。
示例（可用性可能变化）：
  https://ghproxy.com/
  https://mirror.ghproxy.com/
  https://github.moeyy.xyz/
  https://ghfast.top/
EOF
read -r -p "请输入 GitHub 代理前缀（留空=自动选择）: " GH_PROXY
GH_PROXY="${GH_PROXY:-}"

if [[ -z "$GH_PROXY" ]]; then
  info "未指定代理前缀，正在自动探测可用的 GitHub 加速代理…"
  if GH_PROXY="$(pick_working_proxy)"; then
    info "自动选择可用代理：$GH_PROXY"
  else
    warn "未探测到可用代理，将使用直连（若仍超时，请手动指定代理前缀重试）。"
    GH_PROXY=""
  fi
else
  [[ "$GH_PROXY" == */ ]] || GH_PROXY="${GH_PROXY}/"
  info "使用你指定的代理前缀：$GH_PROXY"
fi

SECRET="$(rand_secret)"

echo
info "安装目录：$INSTALL_DIR"
info "mixed-port：$MIXED_PORT"
info "controller：127.0.0.1:$CTRL_PORT"
info "secret：$SECRET"
info "GitHub 代理前缀：${GH_PROXY:-未使用}"
echo

# =========================
# Layout
# =========================
BIN_DIR="$INSTALL_DIR/bin"
RUN_DIR="$INSTALL_DIR/run"
PROV_DIR="$INSTALL_DIR/providers"
mkdir -p "$BIN_DIR" "$RUN_DIR" "$PROV_DIR"

# =========================
# Download mihomo (robust)
# =========================
ARCH="$(detect_arch)"
info "检测到架构：$ARCH"

# 自动获取最新版本号
info "正在获取 mihomo 最新版本号…"
MIHOMO_LATEST_VERSION=""
for api_url in \
  "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
  "https://cdn.jsdelivr.net/gh/MetaCubeX/mihomo@latest/README.md"; do
  MIHOMO_LATEST_VERSION="$(curl -fsSL --connect-timeout 8 --max-time 15 "$api_url" 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)" && break
done

if [[ -z "${MIHOMO_LATEST_VERSION}" ]]; then
  warn "无法自动获取最新版本号，将使用 v1.19.23"
  MIHOMO_LATEST_VERSION="v1.19.23"
fi
info "最新版本：${MIHOMO_LATEST_VERSION}"

# 备用下载源列表（国内镜像）
MIRROR_SOURCES=(
  "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_LATEST_VERSION}/mihomo-linux-${ARCH}-${MIHOMO_LATEST_VERSION}.gz"
)

# 尝试方法1: 使用GitHub代理解析最新版本
DOWNLOAD_SUCCESS=false
TMP_MI="$RUN_DIR/mihomo.gz"

info "尝试方法1：通过GitHub代理下载最新版本…"
if ! $DOWNLOAD_SUCCESS; then
  asset_pat="$(pick_asset_suffix "$ARCH")"
  info "解析最新 mihomo 资产（匹配：$asset_pat）…"

  MIHOMO_URL=""
  MIHOMO_URL_DL=""

  if MIHOMO_URL="$(resolve_mihomo_asset_url "$asset_pat" 2>/dev/null)"; then
    MIHOMO_URL_DL="$(apply_gh_proxy "$MIHOMO_URL")"
    info "mihomo 原始链接：$MIHOMO_URL"
    info "mihomo 下载链接（含代理）：$MIHOMO_URL_DL"

    if curl_get "$MIHOMO_URL_DL" "$TMP_MI" 2>/dev/null; then
      DOWNLOAD_SUCCESS=true
      info "通过GitHub代理下载成功"
    fi
  fi
fi

# 尝试方法2: 使用jsDelivr CDN（国内访问友好）
if ! $DOWNLOAD_SUCCESS; then
  info "尝试方法2：使用jsDelivr CDN下载…"
  CDN_URL="https://cdn.jsdelivr.net/gh/MetaCubeX/mihomo@${MIHOMO_LATEST_VERSION}/mihomo-linux-${ARCH}.gz"

  info "CDN链接：$CDN_URL"
  if curl_get "$CDN_URL" "$TMP_MI" 2>/dev/null; then
    DOWNLOAD_SUCCESS=true
    info "通过jsDelivr CDN下载成功"
  fi
fi

# 尝试方法3: 使用ghproxy镜像
if ! $DOWNLOAD_SUCCESS; then
  info "尝试方法3：使用ghproxy镜像下载…"
  for mirror_url in "${MIRROR_SOURCES[@]}"; do
    for proxy_prefix in "https://ghproxy.net/" "https://gh-proxy.com/" "https://gh.api.99988866.xyz/"; do
      PROXIED_URL="${proxy_prefix}${mirror_url}"
      info "尝试：$PROXIED_URL"
      if curl_get "$PROXIED_URL" "$TMP_MI" 2>/dev/null; then
        DOWNLOAD_SUCCESS=true
        info "通过镜像下载成功"
        break 2
      fi
    done
  done
fi

# 检查下载是否成功
if ! $DOWNLOAD_SUCCESS; then
  die "所有下载方式均失败。请检查网络连接或手动下载 mihomo-linux-${ARCH}.gz 到 $RUN_DIR"
fi

# 如果 mihomo 正在运行，先停止
if [[ -f "$BIN_DIR/mihomo" ]]; then
  info "检测到 mihomo 已安装，正在停止现有进程..."
  pkill -f "mihomo -d.*$INSTALL_DIR" >/dev/null 2>&1 || true
  sleep 1
fi

gunzip -c "$TMP_MI" > "$BIN_DIR/mihomo"
chmod +x "$BIN_DIR/mihomo"
rm -f "$TMP_MI"

info "mihomo 安装完成：$BIN_DIR/mihomo"
if VERSION_OUTPUT=$("$BIN_DIR/mihomo" -v 2>&1); then
  info "mihomo 版本：$VERSION_OUTPUT"
else
  warn "mihomo 版本检测失败，但不一定影响使用"
fi

# =========================
# Write config.yaml
# =========================
SUB_URL_ESCAPED="$(printf '%s' "$SUB_URL" | escape_yaml_double_quotes)"
CONFIG="$INSTALL_DIR/config.yaml"

info "生成 config.yaml …"
cat > "$CONFIG" <<EOF
mixed-port: ${MIXED_PORT}
allow-lan: false
mode: rule
log-level: info

external-controller: 127.0.0.1:${CTRL_PORT}
secret: "${SECRET}"

proxy-providers:
  sub:
    type: http
    url: "${SUB_URL_ESCAPED}"
    interval: 3600
    path: ${PROV_DIR}/sub.yaml
    health-check:
      enable: true
      interval: 300
      url: http://www.gstatic.com/generate_204

proxy-groups:
  - name: "PROXY"
    type: select
    use:
      - sub
  - name: "AUTO"
    type: url-test
    use:
      - sub
    url: http://www.gstatic.com/generate_204
    interval: 300

rules:
  - MATCH,PROXY
EOF
info "写入完成：$CONFIG"
else
  BIN_DIR="$INSTALL_DIR/bin"
  RUN_DIR="$INSTALL_DIR/run"
  PROV_DIR="$INSTALL_DIR/providers"
  CONFIG="$INSTALL_DIR/config.yaml"
  mkdir -p "$RUN_DIR"
  INSTALL_META="$("$RESIDENTIAL_PYTHON" - "$CONFIG" <<'PY'
from pathlib import Path
import sys
import yaml
config = yaml.safe_load(Path(sys.argv[1]).read_text())
port = config.get('mixed-port') or config.get('port')
if not port:
    sys.exit('已有配置缺少 HTTP/mixed 端口')
print(port)
print(str(config.get('external-controller', '')).rsplit(':', 1)[-1])
print(config.get('secret', ''))
PY
  )" || die "无法读取已有安装配置。"
  mapfile -t INSTALL_META_LINES <<< "$INSTALL_META"
  MIXED_PORT="${INSTALL_META_LINES[0]}"
  CTRL_PORT="${INSTALL_META_LINES[1]}"
  SECRET="${INSTALL_META_LINES[2]:-}"
fi

# Generate every residential chain before any service can start.
if [[ "$USE_RESIDENTIAL" =~ ^[Yy]$ ]]; then
  RESIDENTIAL_ARGS=(--install-dir "$INSTALL_DIR" configure)
  if [[ -n "${RESIDENTIAL_SETTINGS_FILE:-}" ]]; then
    RESIDENTIAL_ARGS+=(--settings-file "$RESIDENTIAL_SETTINGS_FILE")
  fi
  if ! bash "$SCRIPT_DIR/residential.sh" "${RESIDENTIAL_ARGS[@]}"; then
    if [[ "$EXISTING_INSTALL" == false ]]; then
      mv "$CONFIG" "$INSTALL_DIR/config.setup-incomplete.yaml"
      die "住宅模式配置失败，未生成可启动的 config.yaml；排查后重新运行本脚本。"
    fi
    die "住宅模式配置失败，已有安装配置已保留；排查后重新运行本脚本。"
  fi
  cleanup_residential_input
fi

# Install a self-contained runtime helper with the verified Python interpreter.
"$RESIDENTIAL_PYTHON" - "$SCRIPT_DIR" "$INSTALL_DIR" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import residential
residential.copy_runtime_tool(Path(sys.argv[2]))
PY

# =========================
# run.sh / stop.sh / status.sh / proxy.sh
# =========================
RUN_SH="$INSTALL_DIR/run.sh"
STOP_SH="$INSTALL_DIR/stop.sh"
STATUS_SH="$INSTALL_DIR/status.sh"
PROXY_SH="$INSTALL_DIR/proxy.sh"

cat > "$RUN_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=$(printf %q "$INSTALL_DIR")
BIN_DIR="\${INSTALL_DIR}/bin"
RUN_DIR="\${INSTALL_DIR}/run"
exec $(printf %q "$RESIDENTIAL_PYTHON") "\${INSTALL_DIR}/residential.py" --install-dir "\${INSTALL_DIR}" start
EOF
chmod +x "$RUN_SH"

cat > "$STOP_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=$(printf %q "$INSTALL_DIR")
RUN_DIR="\${INSTALL_DIR}/run"
PID_FILE="\${RUN_DIR}/mihomo.pid"

stopped=false

# 方法1：通过 PID 文件停止
if [[ -f "\$PID_FILE" ]]; then
  PID=\$(cat "\$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "\${PID}" ]] && kill -0 "\${PID}" >/dev/null 2>&1; then
    kill "\${PID}" 2>/dev/null || true
    sleep 1
    # 如果进程还在，强制杀死
    if kill -0 "\${PID}" >/dev/null 2>&1; then
      kill -9 "\${PID}" 2>/dev/null || true
    fi
    echo "mihomo 已停止（PID: \${PID}）"
    stopped=true
  fi
  rm -f "\$PID_FILE"
fi

# 方法2：查找并停止所有 mihomo 进程
if ! \$stopped; then
  PIDS=\$(pgrep -f "mihomo -d.*${INSTALL_DIR}" || true)
  if [[ -n "\$PIDS" ]]; then
    for pid in \$PIDS; do
      kill "\$pid" 2>/dev/null || true
    done
    sleep 1
    # 强制清理
    PIDS=\$(pgrep -f "mihomo -d.*${INSTALL_DIR}" || true)
    for pid in \$PIDS; do
      kill -9 "\$pid" 2>/dev/null || true
    done
    echo "mihomo 已停止"
    stopped=true
  fi
fi

if ! \$stopped; then
  echo "mihomo 未运行"
fi
EOF
chmod +x "$STOP_SH"

# 创建代理环境变量设置脚本
cat > "$PROXY_SH" <<EOF
#!/usr/bin/env bash
# 使用方法: source ${INSTALL_DIR}/proxy.sh
export http_proxy=http://127.0.0.1:${MIXED_PORT}
export https_proxy=http://127.0.0.1:${MIXED_PORT}
export all_proxy=socks5h://127.0.0.1:${MIXED_PORT}
export HTTP_PROXY=http://127.0.0.1:${MIXED_PORT}
export HTTPS_PROXY=http://127.0.0.1:${MIXED_PORT}
export ALL_PROXY=socks5h://127.0.0.1:${MIXED_PORT}
echo "代理环境变量已设置"
echo "HTTP/SOCKS5: 127.0.0.1:${MIXED_PORT}"
EOF
chmod +x "$PROXY_SH"

# 创建状态检查脚本
cat > "$STATUS_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=$(printf %q "$INSTALL_DIR")
RUN_DIR="\${INSTALL_DIR}/run"
PID_FILE="\${RUN_DIR}/mihomo.pid"
BIN_DIR="\${INSTALL_DIR}/bin"

running=false
pid=""

# 检查 PID 文件
if [[ -f "\$PID_FILE" ]]; then
  PID=\$(cat "\$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "\$PID" ]] && kill -0 "\$PID" >/dev/null 2>&1; then
    running=true
    pid="\$PID"
  fi
fi

# 如果 PID 文件检查失败，尝试查找进程
if ! \$running; then
  PID=\$(pgrep -f "mihomo -d.*${INSTALL_DIR}" | head -n 1 || echo "")
  if [[ -n "\$PID" ]]; then
    running=true
    pid="\$PID"
  fi
fi

echo "mihomo 状态："
echo "=========="
if \$running; then
  echo "运行状态: 运行中"
  echo "进程 ID: \$pid"
  echo "安装目录: ${INSTALL_DIR}"
  echo "代理端口: ${MIXED_PORT}"
  echo "控制端口: ${CTRL_PORT}"
  echo
  echo "最近的日志（最后10行）："
  echo "---"
  tail -n 10 "\${RUN_DIR}/mihomo.log" 2>/dev/null || echo "无日志文件"
else
  echo "运行状态: 未运行"
  echo ""
  echo "启动方式："
  echo "  ${INSTALL_DIR}/run.sh"
fi
echo "=========="
EOF
chmod +x "$STATUS_SH"

UPDATE_METHOD="本次未配置（已有任务保留）"
if [[ "$USE_RESIDENTIAL" =~ ^[Yy]$ ]]; then
  USE_RESIDENTIAL_TIMER="$(ask_yes_no '是否启用每小时自动更新住宅代理链？（Y/n）: ' Y)"
  if [[ "$USE_RESIDENTIAL_TIMER" == Y ]]; then
    if bash "$SCRIPT_DIR/residential.sh" --install-dir "$INSTALL_DIR" timer-install; then
      UPDATE_METHOD="用户 systemd（每小时）"
    elif bash "$SCRIPT_DIR/residential.sh" --install-dir "$INSTALL_DIR" cron-install; then
      UPDATE_METHOD="用户 crontab（每小时）"
    else
      warn "服务器未提供可用的用户定时任务；现有住宅配置可继续使用，订阅更新需手动执行。"
    fi
  fi
else
  UPDATE_METHOD="内核订阅更新（每小时）"
fi

# =========================
# Optional systemd --user
# =========================
echo
USE_SYSTEMD="$(ask_yes_no '是否尝试创建 systemd --user 服务以便守护？（y/N）: ' N)"

if [[ "$USE_SYSTEMD" =~ ^[Yy]$ ]]; then
  ALREADY_RUNNING="$("$RESIDENTIAL_PYTHON" - "$SCRIPT_DIR" "$INSTALL_DIR" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import residential
print('yes' if residential.running(Path(sys.argv[2])) else 'no')
PY
  )"
  if [[ "$ALREADY_RUNNING" == yes ]]; then
    info "mihomo 已运行，沿用现有启动方式。"
  elif command -v systemctl >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    UNIT_NAME="$("$RESIDENTIAL_PYTHON" - "$SCRIPT_DIR" "$INSTALL_DIR" "$UNIT_DIR" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import residential as r
root = Path(sys.argv[2])
name = r.unit_name(root).replace('mihomo-residential-', 'mihomo-') + '.service'
r.atomic_write(Path(sys.argv[3]) / name,
    '[Unit]\nDescription=mihomo proxy (user)\nAfter=network-online.target\n\n'
    '[Service]\nType=simple\nUMask=0077\n'
    f'WorkingDirectory={r.unit_quote(root, command=False)}\n'
    f'ExecStart={r.unit_quote(root / "bin/mihomo")} -d {r.unit_quote(root)}\n'
    'Restart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=default.target\n')
print(name)
PY
    )"
    systemctl --user daemon-reload || warn "systemctl --user daemon-reload 失败"
    systemctl --user enable --now "$UNIT_NAME" || warn "用户服务不可用，将尝试普通用户后台启动。"
  else
    warn "未找到 systemctl，跳过 systemd --user。"
  fi
fi

info "启动并检查 mihomo 服务…"
"$RUN_SH" || die "服务启动失败，请检查 $RUN_DIR/mihomo.log 后重新运行本脚本。"

if [[ "$USE_RESIDENTIAL" =~ ^[Yy]$ ]]; then
  info "检查当前代理链的出口 IP…"
  bash "$SCRIPT_DIR/residential.sh" --install-dir "$INSTALL_DIR" verify \
    --url "${MIHOMO_VERIFY_URL:-https://api.ipify.org}" || \
    die "住宅配置已保存，但出口验证未通过。请检查住宅参数和当前机场节点后重新运行本脚本。"
fi

SETUP_TERMINALS="$(ask_yes_no '是否为新终端和 VSCode 设置代理并注册快捷命令？（Y/n）: ' Y)"
if [[ "$SETUP_TERMINALS" == Y ]]; then
  info "配置新终端和 VSCode 的代理…"
  MIHOMO_PROXY_URL="http://127.0.0.1:$MIXED_PORT" MIHOMO_SOCKS_URL="socks5h://127.0.0.1:$MIXED_PORT" \
    bash "$SCRIPT_DIR/setup_global_proxy.sh" >/dev/null
  INSTALL_DIR="$INSTALL_DIR" bash "$SCRIPT_DIR/register.sh" >/dev/null
  info "已配置。新开终端即可使用；已有 VSCode 远程会话需重新连接。"
fi

# =========================
# Final
# =========================
echo
info "安装完成，mihomo 已运行。"
echo "  代理地址：HTTP/SOCKS5 127.0.0.1:${MIXED_PORT}"
echo "  控制地址：127.0.0.1:${CTRL_PORT}"
echo "  控制密钥：保存在 ${INSTALL_DIR}/config.yaml"
echo "  订阅更新：$UPDATE_METHOD"
if [[ "$USE_RESIDENTIAL" =~ ^[Yy]$ ]]; then
  echo "  住宅出口：当前代理链已通过检测；所有可选节点均使用住宅代理链。"
fi
if [[ "$SETUP_TERMINALS" == Y ]]; then
  echo "  新开终端即可自动使用代理；已有 VSCode 远程会话请重新连接。"
fi
echo "  管理命令：${INSTALL_DIR}/run.sh、stop.sh、status.sh"
echo "  日志文件：${RUN_DIR}/mihomo.log"
echo "  后续更换配置或补全安装，仍可运行本安装脚本。"
