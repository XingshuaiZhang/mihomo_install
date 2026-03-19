#!/usr/bin/env bash
set -euo pipefail

# =========================
# Helpers
# =========================
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

# =========================
# Find mihomo installation
# =========================
detect_install_dir() {
  # 方法1：检查进程
  local pid
  pid=$(pgrep -f "mihomo -d" | head -n 1 || true)
  if [[ -n "$pid" ]]; then
    local cmdline
    cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
    if [[ "$cmdline" =~ mihomo\ -d\ ([^ ]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  # 方法2：检查常见位置
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

INSTALL_DIR="${INSTALL_DIR:-$(detect_install_dir || true)}"

if [[ ! -d "$INSTALL_DIR" ]]; then
  err "无法找到 mihomo 安装目录"
  echo
  echo "请手动指定安装目录："
  echo "  INSTALL_DIR=/path/to/mihomo $0"
  echo
  echo "或确保 mihomo 正在运行"
  exit 1
fi

CONFIG="$INSTALL_DIR/config.yaml"
PROV_DIR="$INSTALL_DIR/providers"
STOP_SH="$INSTALL_DIR/stop.sh"
RUN_SH="$INSTALL_DIR/run.sh"

# 检查必要文件
if [[ ! -f "$CONFIG" ]]; then
  err "配置文件不存在: $CONFIG"
  exit 1
fi

if [[ ! -f "$STOP_SH" ]] || [[ ! -f "$RUN_SH" ]]; then
  err "mihomo 安装不完整，缺少启动脚本"
  exit 1
fi

# =========================
# Main
# =========================
echo "========================================="
echo "  Mihomo 订阅链接更换工具"
echo "========================================="
echo
info "检测到 mihomo 安装目录: $INSTALL_DIR"
echo

echo "当前订阅链接："
grep -A10 'proxy-providers:' "$CONFIG" | grep 'url:' | head -1 | sed 's/^[[:space:]]*/  /' || echo "  (未找到订阅链接)"
echo

read -r -p "请输入新的订阅链接: " NEW_URL
[[ -n "$NEW_URL" ]] || { err "订阅链接不能为空"; exit 1; }

echo
info "测试订阅链接可访问性..."
if curl -fsSL --connect-timeout 10 --max-time 30 "$NEW_URL" >/dev/null 2>&1; then
  info "✓ 订阅链接可访问"
else
  warn "⚠ 警告：订阅链接可能无法访问，但继续执行..."
fi

# 转义 sed 替换部分的特殊字符：\ & |（分隔符）
ESCAPED_URL=$(printf '%s' "$NEW_URL" | sed 's/\\/\\\\/g; s/&/\\&/g; s/|/\\|/g')

# 备份配置
BACKUP_FILE="$CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BACKUP_FILE"
info "已备份原配置到: $BACKUP_FILE"

# 替换订阅链接（替换 proxy-providers 下的第一个 url）
sed -i "0,/url: \".*\"/s|url: \".*\"|url: \"$ESCAPED_URL\"|" "$CONFIG"

echo
info "配置已更新"
echo "新订阅链接：$NEW_URL"
echo

# 删除旧缓存
info "删除旧的订阅缓存..."
rm -f "$PROV_DIR/sub.yaml"

# 重启服务
info "重启 mihomo..."
"$STOP_SH" >/dev/null 2>&1 || true
sleep 2
"$RUN_SH" >/dev/null 2>&1 &

sleep 3

if pgrep -f "mihomo -d" >/dev/null 2>&1; then
  info "✓ mihomo 已成功启动"
else
  warn "⚠ mihomo 可能未能正常启动，请检查日志: tail -f $INSTALL_DIR/run/mihomo.log"
fi

echo
echo "========================================="
info "✓ 订阅更换完成！"
echo "========================================="
echo
echo "后续操作："
echo "  查看状态： $INSTALL_DIR/status.sh"
echo "  查看日志： tail -f $INSTALL_DIR/run/mihomo.log"
echo "  测试代理： curl -x http://127.0.0.1:7890 https://api.ipify.org"
echo
