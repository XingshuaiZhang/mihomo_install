#!/usr/bin/env bash
# mihomo 代理开关
# 用法（在 shell 中）：
#   proxy_on        # 开代理
#   proxy_off       # 关代理
#   proxy_status    # 查看状态
#
# 该文件被 ~/.bashrc 与 ~/.profile 自动 source，
# source 时默认开启代理（静默）。

MIHOMO_PROXY_URL="${MIHOMO_PROXY_URL:-http://127.0.0.1:7890}"
MIHOMO_SOCKS_URL="${MIHOMO_SOCKS_URL:-socks5h://127.0.0.1:7890}"
MIHOMO_NO_PROXY="localhost,127.0.0.1,::1"

proxy_on() {
    export http_proxy="$MIHOMO_PROXY_URL"
    export https_proxy="$MIHOMO_PROXY_URL"
    export all_proxy="$MIHOMO_SOCKS_URL"
    export HTTP_PROXY="$MIHOMO_PROXY_URL"
    export HTTPS_PROXY="$MIHOMO_PROXY_URL"
    export ALL_PROXY="$MIHOMO_SOCKS_URL"
    export no_proxy="$MIHOMO_NO_PROXY"
    export NO_PROXY="$MIHOMO_NO_PROXY"
    [ "${1:-}" = "-q" ] || echo "代理已开启 → $MIHOMO_PROXY_URL"
}

proxy_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
    [ "${1:-}" = "-q" ] || echo "代理已关闭"
}

proxy_status() {
    if [ -n "${HTTPS_PROXY:-}" ] || [ -n "${https_proxy:-}" ]; then
        echo "代理状态: 开启 (${HTTPS_PROXY:-$https_proxy})"
    else
        echo "代理状态: 关闭"
    fi
}

# 被 source 时默认开启
proxy_on -q
