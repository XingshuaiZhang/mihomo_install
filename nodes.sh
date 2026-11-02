#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
step() { echo -e "${BLUE}[TEST]${NC} $*"; }
die() { error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"; }

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

usage() {
  cat <<'EOF'
用法：
  bash ~/tools/mihomo_install/nodes.sh [选项]

功能：
  1. 读取 mihomo 的 PROXY 组节点
  2. 对全部节点进行延迟测试
  3. 在命令行中输入编号手动切换节点

选项：
  -g, --group GROUP      指定要操作的代理组，默认 PROXY
  -u, --url URL          测速 URL，默认 https://www.gstatic.com/generate_204
  -t, --timeout MS       单节点测速超时，默认 5000 毫秒
  -l, --list-only        仅测速并显示结果，不进入切换提示
  -h, --help             显示帮助

环境变量：
  INSTALL_DIR                 手动指定 mihomo 安装目录
  MIHOMO_TEST_CONCURRENCY     并发测速数，默认 6
EOF
}

trim_quotes() {
  local value="$1"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "$value"
}

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

GROUP="PROXY"
TEST_URL="https://www.gstatic.com/generate_204"
TIMEOUT_MS="5000"
LIST_ONLY=false
CONCURRENCY="${MIHOMO_TEST_CONCURRENCY:-6}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--group)
      [[ $# -ge 2 ]] || die "--group 需要一个值"
      GROUP="$2"
      shift 2
      ;;
    -u|--url)
      [[ $# -ge 2 ]] || die "--url 需要一个值"
      TEST_URL="$2"
      shift 2
      ;;
    -t|--timeout)
      [[ $# -ge 2 ]] || die "--timeout 需要一个值"
      TIMEOUT_MS="$2"
      shift 2
      ;;
    -l|--list-only)
      LIST_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "timeout 必须是数字（毫秒）"
[[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "MIHOMO_TEST_CONCURRENCY 必须是数字"
(( CONCURRENCY > 0 )) || die "并发测速数必须大于 0"

need_cmd curl
need_cmd jq
need_cmd sort
need_cmd mktemp

INSTALL_DIR="${INSTALL_DIR:-$(detect_install_dir || true)}"
[[ -n "${INSTALL_DIR:-}" ]] || die "无法找到 mihomo 安装目录，请用 INSTALL_DIR=/path/to/mihomo 指定"

CONFIG_FILE="$INSTALL_DIR/config.yaml"
RUN_SH="$INSTALL_DIR/run.sh"
[[ -f "$CONFIG_FILE" ]] || die "配置文件不存在：$CONFIG_FILE"
[[ -x "$RUN_SH" ]] || die "启动脚本不存在：$RUN_SH"

CONTROLLER_RAW=$(awk -F': ' '/^external-controller:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$CONFIG_FILE")
SECRET_RAW=$(awk -F': ' '/^secret:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$CONFIG_FILE")
CONTROLLER=$(trim_quotes "${CONTROLLER_RAW:-}")
SECRET=$(trim_quotes "${SECRET_RAW:-}")

[[ -n "$CONTROLLER" ]] || die "config.yaml 中缺少 external-controller 配置"
if [[ "$CONTROLLER" == http://* ]] || [[ "$CONTROLLER" == https://* ]]; then
  API_BASE="$CONTROLLER"
else
  API_BASE="http://$CONTROLLER"
fi

AUTH_ARGS=()
if [[ -n "$SECRET" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $SECRET")
fi

api_get() {
  local path="$1"
  curl --noproxy '*' -fsS "${AUTH_ARGS[@]}" "${API_BASE}${path}"
}

api_put_json() {
  local path="$1" payload="$2"
  curl --noproxy '*' -fsS -X PUT \
    "${AUTH_ARGS[@]}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "${API_BASE}${path}" >/dev/null
}

api_get "/version" >/dev/null 2>&1 || die "无法连接 mihomo controller：${API_BASE}，请先启动 mihomo"

PROXIES_JSON="$(api_get "/proxies")"
GROUP_TYPE="$(printf '%s' "$PROXIES_JSON" | jq -r --arg group "$GROUP" '.proxies[$group].type // empty')"
[[ -n "$GROUP_TYPE" ]] || die "找不到代理组：$GROUP"
[[ "$GROUP_TYPE" == "Selector" ]] || die "代理组 $GROUP 不是 Selector，当前类型为 $GROUP_TYPE"

CURRENT_NODE="$(printf '%s' "$PROXIES_JSON" | jq -r --arg group "$GROUP" '.proxies[$group].now // ""')"
mapfile -t NODES < <(printf '%s' "$PROXIES_JSON" | jq -r --arg group "$GROUP" '.proxies[$group].all[]?')
(( ${#NODES[@]} > 0 )) || die "代理组 $GROUP 中没有可选节点"

declare -A NODE_TYPE_BY_NAME
declare -A NODE_ALIVE_BY_NAME

while IFS=$'\t' read -r name type alive; do
  NODE_TYPE_BY_NAME["$name"]="$type"
  NODE_ALIVE_BY_NAME["$name"]="$alive"
done < <(
  printf '%s' "$PROXIES_JSON" | jq -r --arg group "$GROUP" '
    .proxies[$group].all[] as $name
    | [$name, (.proxies[$name].type // "Unknown"), ((.proxies[$name].alive // false) | tostring)]
    | @tsv
  '
)

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

test_node() {
  local index="$1" name="$2"
  local encoded delay_json delay type alive

  encoded="$(urlencode "$name")"
  delay_json="$(
    curl --noproxy '*' -fsS -G \
      "${AUTH_ARGS[@]}" \
      --data-urlencode "url=${TEST_URL}" \
      --data-urlencode "timeout=${TIMEOUT_MS}" \
      --data-urlencode "expected=204" \
      "${API_BASE}/proxies/${encoded}/delay" 2>/dev/null || true
  )"

  delay="$(printf '%s' "$delay_json" | jq -r '.delay // 0' 2>/dev/null || echo 0)"
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=0

  type="${NODE_TYPE_BY_NAME[$name]:-Unknown}"
  alive="${NODE_ALIVE_BY_NAME[$name]:-false}"
  printf '%s\t%s\t%s\t%s\n' "$delay" "$alive" "$type" "$name" > "${TMP_DIR}/${index}.tsv"
}

echo "========================================="
echo "   Mihomo 节点测速与手动切换工具"
echo "========================================="
echo
info "检测到 mihomo 安装目录: $INSTALL_DIR"
info "代理组: $GROUP"
if [[ -f "$INSTALL_DIR/residential-source.yaml" ]]; then
  info "住宅模式：下列节点均经过固定住宅出口，延迟包含整条代理链"
fi
info "当前节点: ${CURRENT_NODE:-未知}"
step "开始测速，共 ${#NODES[@]} 个节点，并发 ${CONCURRENCY}，单节点超时 ${TIMEOUT_MS}ms"
echo

for index in "${!NODES[@]}"; do
  test_node "$index" "${NODES[$index]}" &
  while (( $(jobs -pr | wc -l) >= CONCURRENCY )); do
    sleep 0.1
  done
done
wait

RESULTS_FILE="${TMP_DIR}/results.tsv"
for index in "${!NODES[@]}"; do
  cat "${TMP_DIR}/${index}.tsv"
done | awk -F'\t' '
  {
    sort_key = ($1 > 0 ? sprintf("%08d", $1) : "99999999")
    print sort_key "\t" $0
  }
' | sort -t$'\t' -k1,1 -k5,5 | cut -f2- > "$RESULTS_FILE"

ROW_FORMAT='%s%-4s %-10s %-8s %-14s %s\n'

printf "$ROW_FORMAT" " " "No." "Delay" "Status" "Type" "Node"
printf "$ROW_FORMAT" " " "----" "--------" "------" "------------" "----"

declare -a ORDERED_NODES=()
DISPLAY_INDEX=0
while IFS=$'\t' read -r delay alive type name; do
  (( DISPLAY_INDEX += 1 ))
  ORDERED_NODES[$DISPLAY_INDEX]="$name"

  delay_text="timeout"
  [[ "$delay" -gt 0 ]] && delay_text="${delay}ms"

  status_text="down"
  [[ "$alive" == "true" ]] && status_text="ok"

  prefix=" "
  [[ "$name" == "$CURRENT_NODE" ]] && prefix="*"

  printf "$ROW_FORMAT" "$prefix" "$DISPLAY_INDEX" "$delay_text" "$status_text" "$type" "$name"
done < "$RESULTS_FILE"

echo
echo "* 表示当前正在使用的节点"
echo

if $LIST_ONLY; then
  exit 0
fi

read -r -p "请输入要切换的节点编号（直接回车退出）: " CHOICE
[[ -n "${CHOICE:-}" ]] || exit 0
[[ "$CHOICE" =~ ^[0-9]+$ ]] || die "请输入数字编号"
(( CHOICE >= 1 && CHOICE <= DISPLAY_INDEX )) || die "编号超出范围"

TARGET_NODE="${ORDERED_NODES[$CHOICE]}"
GROUP_PATH="$(urlencode "$GROUP")"
PAYLOAD="$(jq -nc --arg name "$TARGET_NODE" '{name: $name}')"

step "切换 $GROUP -> $TARGET_NODE"
api_put_json "/proxies/${GROUP_PATH}" "$PAYLOAD"

VERIFY_JSON="$(api_get "/proxies")"
NEW_CURRENT="$(printf '%s' "$VERIFY_JSON" | jq -r --arg group "$GROUP" '.proxies[$group].now // ""')"
if [[ "$NEW_CURRENT" != "$TARGET_NODE" ]]; then
  die "切换后校验失败，当前节点仍为：$NEW_CURRENT"
fi

delay_json="$(
  curl --noproxy '*' -fsS -G \
    "${AUTH_ARGS[@]}" \
    --data-urlencode "url=${TEST_URL}" \
    --data-urlencode "timeout=${TIMEOUT_MS}" \
    --data-urlencode "expected=204" \
    "${API_BASE}/proxies/$(urlencode "$TARGET_NODE")/delay" 2>/dev/null || true
)"
new_delay="$(printf '%s' "$delay_json" | jq -r '.delay // 0' 2>/dev/null || echo 0)"

echo
info "切换成功，当前节点：$NEW_CURRENT"
if [[ "$new_delay" =~ ^[0-9]+$ ]] && (( new_delay > 0 )); then
  info "当前延迟：${new_delay}ms"
else
  warn "已切换，但测速未返回有效延迟"
fi
