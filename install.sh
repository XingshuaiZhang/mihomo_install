#!/usr/bin/env bash
set -euo pipefail

# =========================
# Helpers
# =========================
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"; }

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

info "将安装 mihomo（无需 root），并输出 VSCode 端口转发 + yacd（浏览器端）使用指引。"
info "说明：本脚本默认【不在服务器下载 yacd】；你在 Windows 本地访问 yacd 即可。"
echo

# =========================
# Interactive inputs
# =========================
default_dir="$HOME/tools/mihomo"
read -r -p "请输入安装目录（默认：${default_dir}）: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$default_dir}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

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

# 备用下载源列表（国内镜像）
MIRROR_SOURCES=(
  "https://github.com/MetaCubeX/mihomo/releases/download/v1.18.10/mihomo-linux-${ARCH}-v1.18.10.gz"
  "https://github.com/MetaCubeX/mihomo/releases/download/v1.18.9/mihomo-linux-${ARCH}-v1.18.9.gz"
  "https://github.com/MetaCubeX/mihomo/releases/download/v1.18.8/mihomo-linux-${ARCH}-v1.18.8.gz"
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
  info "尝试方法2：使用jsDelivr CDN下载固定版本…"
  VERSION="v1.18.10"
  CDN_URL="https://cdn.jsdelivr.net/gh/MetaCubeX/mihomo@${VERSION}/mihomo-linux-${ARCH}.gz"

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

INSTALL_DIR="$(printf %q "$INSTALL_DIR")"
BIN_DIR="\${INSTALL_DIR}/bin"
RUN_DIR="\${INSTALL_DIR}/run"

cd "\${INSTALL_DIR}"
mkdir -p "\${RUN_DIR}"

# 检查是否已在运行
PID_FILE="\${RUN_DIR}/mihomo.pid"
if [[ -f "\$PID_FILE" ]]; then
  OLD_PID=\$(cat "\$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "\${OLD_PID}" ]] && kill -0 "\${OLD_PID}" >/dev/null 2>&1; then
    echo "mihomo 已经在运行（pid=\${OLD_PID}）"
    echo "如需重启，请先运行 ${INSTALL_DIR}/stop.sh"
    exit 0
  fi
fi

# 启动 mihomo
nohup "\${BIN_DIR}/mihomo" -d "\${INSTALL_DIR}" > "\${RUN_DIR}/mihomo.log" 2>&1 &
PID=\$!
echo \$! > "\${PID_FILE}"

echo "mihomo 启动成功"
echo "PID: \${PID}"
echo "日志: tail -f ${RUN_DIR}/mihomo.log"
echo
echo "代理地址："
echo "  HTTP/SOCKS5: 127.0.0.1:${MIXED_PORT}"
echo "  控制面板: 127.0.0.1:${CTRL_PORT}"
echo
echo "设置环境变量："
echo "  export http_proxy=http://127.0.0.1:${MIXED_PORT}"
echo "  export https_proxy=http://127.0.0.1:${MIXED_PORT}"
EOF
chmod +x "$RUN_SH"

cat > "$STOP_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(printf %q "$INSTALL_DIR")"
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
export all_proxy=socks5://127.0.0.1:${MIXED_PORT}
export HTTP_PROXY=http://127.0.0.1:${MIXED_PORT}
export HTTPS_PROXY=http://127.0.0.1:${MIXED_PORT}
export ALL_PROXY=socks5://127.0.0.1:${MIXED_PORT}
echo "代理环境变量已设置"
echo "HTTP/SOCKS5: 127.0.0.1:${MIXED_PORT}"
EOF
chmod +x "$PROXY_SH"

# 创建状态检查脚本
cat > "$STATUS_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(printf %q "$INSTALL_DIR")"
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

# =========================
# Optional systemd --user
# =========================
echo
read -r -p "是否尝试创建 systemd --user 服务以便守护？（y/N）: " USE_SYSTEMD
USE_SYSTEMD="${USE_SYSTEMD:-N}"

if [[ "$USE_SYSTEMD" =~ ^[Yy]$ ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/mihomo.service" <<EOF
[Unit]
Description=mihomo proxy (user)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_DIR}/mihomo -d ${INSTALL_DIR}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload || warn "systemctl --user daemon-reload 失败"
    systemctl --user enable --now mihomo.service || warn "启用/启动失败，可继续用 run.sh"
  else
    warn "未找到 systemctl，跳过 systemd --user。"
  fi
fi

# =========================
# Final
# =========================
echo
info "安装完成 ✅"
echo
info "========== 使用说明 =========="
echo
echo "【启动和停止】"
echo "  启动：  ${INSTALL_DIR}/run.sh"
echo "  停止：  ${INSTALL_DIR}/stop.sh"
echo "  状态：  ${INSTALL_DIR}/status.sh"
echo "  重启：  ${INSTALL_DIR}/stop.sh && ${INSTALL_DIR}/run.sh"
echo "  日志：  tail -f ${RUN_DIR}/mihomo.log"
echo
echo "【VSCode 端口转发设置】"
echo "  1. 在VSCode中按 F1 或 Ctrl+Shift+P"
echo "  2. 输入 \"Forward a Port\" 或 \"转发端口\""
echo "  3. 输入端口号：${CTRL_PORT}"
echo "  4. 转发成功后会在 VSCode 底部显示"
echo
echo "【yacd 可视化界面】"
echo "  yacd 在线入口（任选其一）："
echo "    https://yacd.metacubex.one"
echo "    https://yacd.haishan.me"
echo "  在 yacd 中填入："
echo "    主机：127.0.0.1"
echo "    端口：${CTRL_PORT}"
echo "    密钥：${SECRET}"
echo "  提示：如果通过VSCode端口转发，使用 localhost:${CTRL_PORT}"
echo
echo "【设置系统代理】"
echo "  临时设置（当前终端）："
echo "    source ${INSTALL_DIR}/proxy.sh"
echo "  或者手动设置："
echo "    export http_proxy=http://127.0.0.1:${MIXED_PORT}"
echo "    export https_proxy=http://127.0.0.1:${MIXED_PORT}"
echo "    export all_proxy=socks5://127.0.0.1:${MIXED_PORT}"
echo
echo "  永久设置（添加到 ~/.bashrc）："
echo "    echo 'export http_proxy=http://127.0.0.1:${MIXED_PORT}' >> ~/.bashrc"
echo "    echo 'export https_proxy=http://127.0.0.1:${MIXED_PORT}' >> ~/.bashrc"
echo "    source ~/.bashrc"
echo
echo "【测试代理】"
echo "  curl -x http://127.0.0.1:${MIXED_PORT} https://api.ipify.org"
echo "  或设置代理后："
echo "  curl https://api.ipify.org"
echo
echo "【快速切换节点】"
echo "  通过 yacd 界面可以方便地切换节点"
echo "  支持节点延迟测试和自动选择最快节点"
echo
echo "【订阅更新】"
echo "  订阅会每小时自动更新"
echo "  代理节点每5分钟进行健康检查"
echo "================================"