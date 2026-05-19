#!/usr/bin/env bash
# 把 mihomo 代理设为全局可用：
#   1) 在 ~/.bashrc 顶部（早返回之前）注入 source proxy_toggle.sh
#   2) 在 ~/.profile 中同样注入，保证登录 shell / vscode-server 也继承
#   3) 在 VSCode Remote Machine settings.json 中写入 http.proxy 等键
#
# 用法：
#   bash setup_global_proxy.sh           # 安装
#   bash setup_global_proxy.sh --uninstall  # 卸载
#
# 安装为幂等：重复运行不会重复注入。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOGGLE_FILE="${SCRIPT_DIR}/proxy_toggle.sh"
BEGIN_MARK="# >>> mihomo-proxy >>>"
END_MARK="# <<< mihomo-proxy <<<"
VSCODE_SETTINGS="${HOME}/.vscode-server/data/Machine/settings.json"

ACTION="install"
if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
    ACTION="uninstall"
fi

# ----- 移除已有标记块 -----
strip_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if ! grep -qF "$BEGIN_MARK" "$file"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b {skip=1; next}
        $0 == e {skip=0; next}
        !skip {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "  已清理 $file 中的旧标记块"
}

# ----- 注入标记块 -----
inject_block_top() {
    local file="$1"
    touch "$file"
    strip_block "$file"
    local tmp
    tmp="$(mktemp)"
    {
        echo "$BEGIN_MARK"
        echo "[ -f \"$TOGGLE_FILE\" ] && . \"$TOGGLE_FILE\""
        echo "$END_MARK"
        echo
        cat "$file"
    } > "$tmp"
    mv "$tmp" "$file"
    echo "  已注入 $file"
}

# ----- 更新 vscode 设置 -----
update_vscode_settings() {
    local file="$VSCODE_SETTINGS"
    mkdir -p "$(dirname "$file")"
    if [[ ! -f "$file" ]]; then
        cat > "$file" <<'JSON'
{
    "http.proxy": "http://127.0.0.1:7890",
    "http.proxyStrictSSL": false,
    "http.proxySupport": "on"
}
JSON
        echo "  已创建 $file"
        return
    fi
    cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$file" <<'PY'
import json, re, sys, pathlib
p = pathlib.Path(sys.argv[1])
raw = p.read_text(encoding="utf-8")
# 容错：去掉 //... 行注释与对象/数组末尾多余的逗号（VSCode 使用 JSONC）
no_comments = re.sub(r"^\s*//.*$", "", raw, flags=re.MULTILINE)
no_trailing = re.sub(r",(\s*[}\]])", r"\1", no_comments)
try:
    data = json.loads(no_trailing) if no_trailing.strip() else {}
except json.JSONDecodeError as e:
    print(f"  无法解析 settings.json：{e}", file=sys.stderr)
    print("  已备份原文件，未做修改", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("  settings.json 顶层不是对象，已跳过", file=sys.stderr)
    sys.exit(1)
data["http.proxy"] = "http://127.0.0.1:7890"
data["http.proxyStrictSSL"] = False
data["http.proxySupport"] = "on"
p.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
print("  已更新 settings.json（原文件已备份为 .bak.*）")
PY
}

# ----- 移除 vscode 代理键 -----
remove_vscode_proxy_keys() {
    local file="$VSCODE_SETTINGS"
    [[ -f "$file" ]] || return 0
    cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$file" <<'PY'
import json, re, sys, pathlib
p = pathlib.Path(sys.argv[1])
raw = p.read_text(encoding="utf-8")
no_comments = re.sub(r"^\s*//.*$", "", raw, flags=re.MULTILINE)
no_trailing = re.sub(r",(\s*[}\]])", r"\1", no_comments)
try:
    data = json.loads(no_trailing) if no_trailing.strip() else {}
except json.JSONDecodeError as e:
    print(f"  无法解析 settings.json：{e}", file=sys.stderr)
    sys.exit(1)
for k in ("http.proxy", "http.proxyStrictSSL", "http.proxySupport"):
    data.pop(k, None)
p.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
print("  已移除 settings.json 中的代理键")
PY
}

echo "===================================="
echo " mihomo 全局代理配置"
echo " 动作：$ACTION"
echo "===================================="

if [[ "$ACTION" == "install" ]]; then
    if [[ ! -f "$TOGGLE_FILE" ]]; then
        echo "找不到 $TOGGLE_FILE" >&2
        exit 1
    fi
    echo "[1/3] 注入 ~/.bashrc"
    inject_block_top "${HOME}/.bashrc"
    echo "[2/3] 注入 ~/.profile"
    inject_block_top "${HOME}/.profile"
    echo "[3/3] 更新 VSCode Remote settings.json"
    update_vscode_settings

    cat <<EOF

完成。后续操作：

  1. 当前已经打开的终端：执行
       source ~/.bashrc
     或重新打开终端。

  2. 让 VSCode 远程扩展也走代理（修复 Claude Code 登录 403）：
     在 VSCode 命令面板执行 "Remote-SSH: Kill VS Code Server on Host..."，
     然后重新连接。

  3. 验证：
       echo \$HTTPS_PROXY                           # 应输出 http://127.0.0.1:7890
       curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com

  4. 开关：
       proxy_on       # 开代理
       proxy_off      # 关代理
       proxy_status   # 查看状态

EOF
else
    echo "[1/3] 从 ~/.bashrc 移除"
    strip_block "${HOME}/.bashrc"
    echo "[2/3] 从 ~/.profile 移除"
    strip_block "${HOME}/.profile"
    echo "[3/3] 移除 VSCode settings.json 中的代理键"
    remove_vscode_proxy_keys
    echo
    echo "已卸载。请重新打开终端，并在 VSCode 中执行 \"Remote-SSH: Kill VS Code Server on Host...\" 让设置生效。"
fi
