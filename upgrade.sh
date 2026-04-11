#!/usr/bin/env bash
set -euo pipefail

# =========================
# mihomo upgrade script
# =========================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"; }

need_cmd curl
need_cmd gunzip
need_cmd jq

# =========================
# Detect mihomo install dir
# =========================
detect_install_dir() {
  local pid cmdline dir cwd

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
    if [[ "$cmdline" =~ [[:space:]]-d[[:space:]]([^[:space:]]+) ]]; then
      dir="${BASH_REMATCH[1]}"
      if [[ "$dir" != /* ]]; then
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "")
        [[ -n "$cwd" ]] || continue
        dir="$(readlink -f "$cwd/$dir" 2>/dev/null || echo "")"
      fi
      if [[ -n "$dir" ]] && [[ -f "$dir/config.yaml" ]] && [[ -f "$dir/run.sh" ]]; then
        echo "$dir"
        return 0
      fi
    fi
  done < <(pgrep -x mihomo || true)

  local common_dirs=(
    "$HOME/tools/mihomo"
    "$HOME/mihomo"
    "/opt/mihomo"
  )

  for dir in "${common_dirs[@]}"; do
    if [[ -f "$dir/config.yaml" ]] && [[ -f "$dir/run.sh" ]]; then
      echo "$dir"
      return 0
    fi
  done

  return 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

# =========================
# GitHub proxy handling
# =========================
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
# Main
# =========================
INSTALL_DIR="${INSTALL_DIR:-$(detect_install_dir || true)}"
[[ -n "${INSTALL_DIR:-}" ]] || die "无法找到 mihomo 安装目录，请用 INSTALL_DIR=/path/to/mihomo 指定"

BIN_DIR="$INSTALL_DIR/bin"
RUN_DIR="$INSTALL_DIR/run"
[[ -f "$BIN_DIR/mihomo" ]] || die "mihomo 二进制不存在：$BIN_DIR/mihomo"

ARCH="$(detect_arch)"

# Current version
CURRENT_VERSION="$("$BIN_DIR/mihomo" -v 2>&1 | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown")"
info "当前版本：${CURRENT_VERSION}"
info "安装目录：${INSTALL_DIR}"
info "系统架构：${ARCH}"
echo

# =========================
# Get latest version
# =========================
step "获取最新版本号…"
LATEST_VERSION=""

# Method 1: GitHub API
LATEST_VERSION="$(curl -fsSL --connect-timeout 8 --max-time 15 \
  "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
  | jq -r '.tag_name // empty')"

# Method 2: Parse releases/latest page
if [[ -z "${LATEST_VERSION}" ]]; then
  GH_PROXY="${GH_PROXY:-}"
  if [[ -z "$GH_PROXY" ]]; then
    GH_PROXY="$(pick_working_proxy 2>/dev/null || true)"
  fi

  latest_url="https://github.com/MetaCubeX/mihomo/releases/latest"
  [[ -n "$GH_PROXY" ]] && latest_url="${GH_PROXY}${latest_url}"

  LATEST_VERSION="$(curl -fsSL --connect-timeout 8 --max-time 15 "$latest_url" 2>/dev/null \
    | grep -oP '/MetaCubeX/mihomo/releases/download/\Kv\d+\.\d+\.\d+' | head -1 || true)"
fi

if [[ -z "${LATEST_VERSION}" ]]; then
  warn "无法自动获取最新版本号，请手动指定：LATEST_VERSION=vX.Y.Z bash $0"
  LATEST_VERSION="v1.19.23"
  warn "将使用 fallback 版本：${LATEST_VERSION}"
fi

info "最新版本：${LATEST_VERSION}"

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
  info "已经是最新版本，无需升级。"
  read -r -p "是否仍然要重新安装？(y/N): " FORCE
  [[ "${FORCE:-}" =~ ^[Yy]$ ]] || exit 0
fi

echo

# =========================
# Download
# =========================
TMP_GZ="$(mktemp /tmp/mihomo-upgrade-XXXXXX.gz)"
cleanup() { rm -f "$TMP_GZ"; }
trap cleanup EXIT

DL_SUCCESS=false
ASSET_NAME="mihomo-linux-${ARCH}-${LATEST_VERSION}.gz"

# Build download URLs
DIRECT_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${ASSET_NAME}"

download_with_proxy() {
  local url="$1" label="$2"
  info "尝试 ${label}…"
  if curl -fL --retry 5 --retry-delay 2 --retry-connrefused \
       --connect-timeout 15 --max-time 300 -o "$TMP_GZ" "$url" 2>/dev/null; then
    DL_SUCCESS=true
    info "${label} 下载成功"
  fi
}

# Method 1: Direct
if ! $DL_SUCCESS; then
  download_with_proxy "$DIRECT_URL" "直连下载"
fi

# Method 2: GitHub proxies
if ! $DL_SUCCESS; then
  # Auto-detect proxy if not set
  if [[ -z "${GH_PROXY:-}" ]]; then
    GH_PROXY="$(pick_working_proxy 2>/dev/null || true)"
  fi

  if [[ -n "$GH_PROXY" ]]; then
    download_with_proxy "${GH_PROXY}${DIRECT_URL}" "代理下载 (${GH_PROXY})"
  fi
fi

# Method 3: Try all known proxies
if ! $DL_SUCCESS; then
  for proxy in "${DEFAULT_PROXY_CANDIDATES[@]}"; do
    download_with_proxy "${proxy}${DIRECT_URL}" "代理下载 (${proxy})" && break
  done
fi

if ! $DL_SUCCESS; then
  die "所有下载方式均失败。请检查网络或手动下载：${DIRECT_URL}"
fi

# =========================
# Verify & Install
# =========================
file "$TMP_GZ" | grep -q "gzip" || die "下载的文件不是 gzip 格式"

step "停止 mihomo…"
if [[ -x "$INSTALL_DIR/stop.sh" ]]; then
  "$INSTALL_DIR/stop.sh" 2>/dev/null || true
else
  pkill -f "mihomo -d.*$INSTALL_DIR" 2>/dev/null || true
fi
sleep 1

step "安装新版本…"
gunzip -c "$TMP_GZ" > "$BIN_DIR/mihomo.tmp"
mv "$BIN_DIR/mihomo.tmp" "$BIN_DIR/mihomo"
chmod +x "$BIN_DIR/mihomo"

NEW_VERSION="$("$BIN_DIR/mihomo" -v 2>&1)"
info "新版本：${NEW_VERSION}"

# =========================
# Restart
# =========================
step "启动 mihomo…"
if [[ -x "$INSTALL_DIR/run.sh" ]]; then
  "$INSTALL_DIR/run.sh"
else
  nohup "$BIN_DIR/mihomo" -d "$INSTALL_DIR" > "$RUN_DIR/mihomo.log" 2>&1 &
  echo "$!" > "$RUN_DIR/mihomo.pid"
  info "mihomo 已启动 (PID: $(cat "$RUN_DIR/mihomo.pid"))"
fi

sleep 2
echo
info "升级完成！"
info "  旧版本：${CURRENT_VERSION}"
info "  新版本：${LATEST_VERSION}"
echo
echo "  查看日志：tail -f ${RUN_DIR}/mihomo.log"
