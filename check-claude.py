#!/usr/bin/env python3
"""通过 mihomo 调用 Net.Coffee 检测页所用接口，在终端显示结果。

依赖 Python 3 和 curl；不会修改 mihomo 配置。使用 --json 输出原始检测数据。
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlsplit


PAGE = "https://ip.net.coffee/claude/"
BASE = "https://ip.net.coffee"
TRACE_URLS = {
    "claude": "https://claude.ai/cdn-cgi/trace",
    "cloudflare": "https://1.1.1.1/cdn-cgi/trace",
    "anthropic": "https://www.anthropic.com/cdn-cgi/trace",
}


def fetch(url, proxy, timeout):
    """Explicit proxy and empty noproxy prevent environment-based bypasses."""
    cmd = [
        "curl", "--disable", "--silent", "--show-error", "--fail",
        "--location", "--proto", "=https", "--proto-redir", "=https",
        "--noproxy", "", "--proxy", proxy,
        "--connect-timeout", str(min(timeout, 10)), "--max-time", str(timeout),
        "--write-out", "\n%{http_code}\t%{time_total}", url,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout + 5)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "请求超时"}
    body, _, meta = p.stdout.rpartition("\n")
    try:
        status, elapsed = meta.split("\t")
        result = {"status": int(status), "seconds": float(elapsed)}
    except ValueError:
        result = {}
    if p.returncode:
        reasons = {5: "无法解析代理地址", 6: "无法解析目标地址",
                   7: "无法连接代理或目标", 22: "HTTP 请求失败",
                   28: "请求超时", 35: "TLS 握手失败", 60: "TLS 证书校验失败"}
        result.update(ok=False, error=reasons.get(p.returncode, "curl 请求失败"),
                      curl_exit_code=p.returncode)
    else:
        result.update(ok=True, body=body)
    return result


def trace_result(result):
    result = dict(result)
    body = result.pop("body", "")
    if result["ok"]:
        trace = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        try:
            trace["ip"] = str(ipaddress.ip_address(trace.get("ip", "")))
        except ValueError:
            result.update(ok=False, error="响应未包含有效出口 IP")
        else:
            result["trace"] = trace
    return result


def json_result(result):
    result = dict(result)
    body = result.pop("body", "")
    if result["ok"]:
        try:
            data = json.loads(body)
            if not isinstance(data, dict) or data.get("error"):
                raise ValueError()
            result["data"] = data
        except ValueError:
            result.update(ok=False, error="接口未返回有效 JSON 对象")
    return result


def risk_scope(ip, data):
    """Net.Coffee may return a representative IP for a cached CIDR."""
    try:
        actual = ipaddress.ip_address(ip)
        reported = ipaddress.ip_address(data.get("ip", ""))
        if actual == reported:
            return "exact"
        network = ipaddress.ip_network(data.get("cidr", ""), strict=False)
        if actual in network and reported in network:
            return "subnet"
    except (ValueError, TypeError):
        pass
    return "unverified"


def bool_text(value, yes, no):
    return yes if value is True else no if value is False else "未知"


def problem(result):
    status = result.get("status")
    return result.get("error", "未知错误") + (f"（HTTP {status}）" if status else "")


def render(report):
    print("Net.Coffee · Ubuntu 代理出口检测")
    print(f"检测时间：{report['time']}")
    print(f"检测页面：{PAGE}")
    print(f"安装目录：{report['install_dir']}")
    print(f"代理地址：{report['proxy']}")
    page = report["page"]
    print("页面访问：" + (f"HTTP {page['status']}" if page["ok"] else problem(page)))
    print()
    for key, label in [("claude", "Claude 出口"), ("cloudflare", "Cloudflare 出口"),
                       ("anthropic", "Anthropic 出口")]:
        result = report["checks"][key]
        if result["ok"]:
            trace = result["trace"]
            print(f"{label}：{trace['ip']}  地区={trace.get('loc', '未知')}  "
                  f"HTTP {result['status']}  耗时 {result['seconds']:.2f}s")
        else:
            print(f"{label}：检测失败，{problem(result)}")

    if report.get("expected_ip"):
        match = report.get("expected_match")
        print(f"预期住宅出口：{report['expected_ip']}（"
              + bool_text(match, "与 Claude 实测一致", "与 Claude 实测不一致") + "）")
    print()
    risk = report.get("risk", {})
    geo = report.get("geo", {}).get("data", {})
    data = risk.get("data", {})
    scope = report.get("risk_scope")
    if geo:
        print("出口归属：" + " / ".join(str(geo[k]) for k in
              ["country", "region", "city", "isp"] if geo.get(k)))
    if data and scope in {"exact", "subnet"}:
        score = data.get("trust_score")
        score_text = f"{score}/100" if type(score) in (int, float) and 0 <= score <= 100 else "未知"
        print(f"网站 Trust Score（第三方）：{score_text}")
        print("网站 IP 属性：" + bool_text(data.get("isResidential"), "住宅 IP", "非住宅 IP"))
        print(f"ASN：{data.get('asn', '未知')}  运营商：{data.get('asOrganization', '未知')}")
        for label, key in [("VPN", "is_vpn"), ("代理标记", "is_proxy"),
                           ("Tor", "is_tor"), ("机器人标记", "is_crawler"),
                           ("滥用记录", "is_abuser")]:
            print(f"{label}：{bool_text(data.get(key), '检测到', '未检测到')}")
        if scope == "subnet":
            print(f"数据范围：{data['cidr']}；接口返回代表 IP {data['ip']}，与实测 IP 不同。")
            print("以上属性和评分仅作网段参考；实际出口以 Claude trace 为准。")
    elif risk:
        print("风险评分：未确认，" + ("接口返回的 IP/网段与实测出口不匹配"
              if risk.get("ok") else problem(risk)))
    else:
        print("风险评分：未查询，未取得 Claude 出口 IP")
    if report.get("geo") and not report["geo"]["ok"]:
        print("归属接口：" + problem(report["geo"]))

    print()
    print("出口检查：" + report["summary"])
    print("检测范围：仅本次显式使用代理的请求；不代表服务器所有程序都经过代理。")
    print("DNS 泄露、WebRTC/UDP、浏览器指纹：本终端检测未执行，也不代表 Mac 浏览器结果。")
    print("trace 连通与第三方评分不等于 Claude 登录或 API 调用成功。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-dir", default=os.environ.get("INSTALL_DIR") or str(Path.home() / "tools/mihomo"),
                        help="mihomo 安装目录，默认 ~/tools/mihomo，也可用 INSTALL_DIR")
    parser.add_argument("--proxy", default="http://127.0.0.1:7890", help="显式代理地址")
    parser.add_argument("--timeout", type=int, default=25, help="单次请求超时秒数，默认 25")
    parser.add_argument("--expected-ip", help="预期住宅出口；默认读取安装目录 residential.json 的 expected_exit_ip")
    parser.add_argument("--json", action="store_true", help="输出 JSON，含接口原始数据")
    args = parser.parse_args()
    if not shutil.which("curl"):
        parser.error("需要安装 curl")
    proxy = urlsplit(args.proxy)
    if proxy.scheme not in {"http", "https", "socks5h"} or not proxy.hostname:
        parser.error("代理地址需要使用 http://、https:// 或 socks5h://")
    if proxy.username is not None or proxy.password is not None:
        parser.error("请使用本地 mihomo 无认证端口，避免在命令行传入代理凭据")
    if not 1 <= args.timeout <= 120:
        parser.error("--timeout 需要在 1–120 秒之间")
    install_dir = Path(args.install_dir).expanduser().resolve()
    expected = args.expected_ip
    if expected is None:
        try:
            settings = json.loads((install_dir / "residential.json").read_text())
            expected = settings.get("expected_exit_ip") if isinstance(settings, dict) else None
        except (OSError, ValueError):
            expected = None
    if expected:
        try:
            expected = str(ipaddress.ip_address(expected))
        except ValueError:
            parser.error("预期出口不是有效的 IP 地址")

    report = {"time": datetime.now().astimezone().isoformat(timespec="seconds"),
              "install_dir": str(install_dir), "proxy": args.proxy, "expected_ip": expected,
              "untested": ["DNS 泄露", "WebRTC/UDP", "浏览器指纹", "Claude 登录/API 调用"]}
    if not args.json:
        print("正在通过 mihomo 请求检测页面和出口接口…", file=sys.stderr, flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        jobs = {name: pool.submit(fetch, url, args.proxy, args.timeout)
                for name, url in {"page": PAGE, **TRACE_URLS}.items()}
        report["page"] = jobs.pop("page").result()
        report["page"].pop("body", None)
        report["checks"] = {name: trace_result(job.result()) for name, job in jobs.items()}
        claude = report["checks"]["claude"]
        if claude["ok"]:
            ip = claude["trace"]["ip"]
            report["expected_match"] = ip == expected if expected else None
            jobs = {name: pool.submit(fetch, f"{BASE}/api/{endpoint}/{ip}", args.proxy, args.timeout)
                    for name, endpoint in [("risk", "iprisk"), ("geo", "geoip")]}
            report.update({name: json_result(job.result()) for name, job in jobs.items()})
            report["risk_scope"] = risk_scope(ip, report["risk"].get("data", {}))

    matches = report.get("expected_match")
    if not report["checks"]["claude"]["ok"]:
        report["summary"] = "未通过：未取得 Claude 出口 IP。"
    elif matches is False:
        report["summary"] = "未通过：Claude 实际出口与预期住宅 IP 不一致。"
    elif matches is True:
        report["summary"] = "通过：Claude 实际出口与预期住宅 IP 一致。"
    else:
        report["summary"] = "已取得 Claude 实际出口；未设置预期住宅 IP，未验证是否为指定出口。"
    exits = {r["trace"]["ip"] for r in report["checks"].values() if r["ok"]}
    if len(exits) > 1:
        report["summary"] += " 不同目标的出口不一致，请检查分流或动态出口。"
    complete = (report["page"]["ok"] and all(r["ok"] for r in report["checks"].values())
                and report.get("risk_scope") in {"exact", "subnet"}
                and report.get("geo", {}).get("ok", False)
                and matches is not False and len(exits) == 1)
    report["complete"] = complete
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        render(report)
    return 0 if complete else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
