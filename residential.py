#!/usr/bin/env python3
"""Manage fixed residential exits for installations created by install.sh."""

import argparse
import copy
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import URLError
from urllib.parse import quote, urlsplit
from urllib.request import ProxyHandler, Request, build_opener

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML。请在项目目录运行 bash setup_python.sh，再通过 bash residential.sh 执行（无需管理员权限）。")

PREFIX = "内部中转｜"
SETTINGS = "residential.json"
SOURCE = "residential-source.yaml"
CACHE = "residential-subscription.yaml"
RESERVED = {"PROXY", "AUTO", "GLOBAL", "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"}
MAX_SUBSCRIPTION = 16 * 1024 * 1024


class UserError(Exception):
    pass


def dump_yaml(value):
    return yaml.safe_dump(value, allow_unicode=True, sort_keys=False)


def read_yaml(path):
    try:
        value = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (yaml.YAMLError, UnicodeError):
        raise UserError(f"YAML 格式错误：{Path(path).name}") from None
    if not isinstance(value, dict):
        raise UserError(f"需要 YAML 对象：{Path(path).name}")
    return value


def atomic_write(path, data):
    """Keep credentials private, including temporary files and replacements."""
    path = Path(path)
    if isinstance(data, str):
        data = data.encode("utf-8")
    fd, name = tempfile.mkstemp(prefix=".residential-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def validate_settings(value):
    if not isinstance(value, dict):
        raise UserError("住宅配置必须是 JSON 对象")
    allowed = {"server", "port", "username", "password", "udp", "expected_exit_ip"}
    if set(value) - allowed:
        raise UserError("住宅配置包含未知字段，请参考 residential.example.json")
    value = dict(value)
    for key in ("server", "username", "password"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise UserError(f"住宅配置缺少非空字符串字段：{key}")
    if any(c.isspace() for c in value["server"]) or "://" in value["server"]:
        raise UserError("server 只填写 IP 或域名，不含协议和端口")
    if type(value.get("port")) is not int or not 1 <= value["port"] <= 65535:
        raise UserError("port 必须是 1–65535 的整数")
    value.setdefault("udp", False)
    if type(value["udp"]) is not bool:
        raise UserError("udp 必须是 true 或 false")
    value.setdefault("expected_exit_ip", "")
    if not isinstance(value["expected_exit_ip"], str):
        raise UserError("expected_exit_ip 必须是字符串")
    if value["expected_exit_ip"]:
        try:
            value["expected_exit_ip"] = str(ipaddress.ip_address(value["expected_exit_ip"]))
        except ValueError:
            raise UserError("expected_exit_ip 必须是供应商分配的实际出口 IP") from None
    return value


def read_settings(path):
    try:
        return validate_settings(json.loads(Path(path).read_text(encoding="utf-8")))
    except (json.JSONDecodeError, UnicodeError):
        raise UserError("住宅配置不是有效的 UTF-8 JSON") from None


def parse_proxy_input(answer):
    """Parse host:port@username:password without interpreting password characters."""
    endpoint, separator, auth = answer.partition("@")
    server, colon, port = endpoint.rpartition(":")
    username, auth_colon, password = auth.partition(":")
    if (not separator or not colon or not auth_colon or not server or not username or not password
            or any(ord(char) < 32 or ord(char) == 127 for char in answer)):
        raise UserError("请按 IP:端口@用户名:密码 填写，四项均不能为空")
    if server.startswith("[") and server.endswith("]"):
        try:
            server = str(ipaddress.IPv6Address(server[1:-1]))
        except ValueError:
            raise UserError("方括号内必须是有效的 IPv6 地址") from None
    elif any(char in server for char in ":/[]?#"):
        raise UserError("地址只填 IP 或域名；IPv6 请使用 [IPv6]:端口@用户名:密码")
    if not port.isascii() or not port.isdecimal() or len(port) > 5:
        raise UserError("端口必须是 1–65535 的整数")
    return validate_settings({"server": server, "port": int(port), "username": username, "password": password})


def prompt_line(prompt, secret=False):
    if sys.stdin.isatty():
        return getpass.getpass(prompt) if secret else input(prompt)
    # Do not buffer later answers belonging to the parent install.sh process.
    # Piped input has no terminal echo; interactive credentials use getpass above.
    print(prompt, end="", flush=True)
    answer = bytearray()
    while True:
        char = os.read(sys.stdin.fileno(), 1)
        if not char:
            if not answer:
                raise EOFError
            break
        if char == b"\n":
            break
        answer.extend(char)
    value = answer.decode(sys.stdin.encoding or "utf-8")
    return value[:-1] if value.endswith("\r") else value


def prompt_settings(old):
    print("住宅 SOCKS5：请一次粘贴 IP:端口@用户名:密码（也支持域名，输入不回显）。", flush=True)
    if old:
        print("已保存住宅参数：直接回车保留，或粘贴新参数替换。", flush=True)
    while True:
        answer = prompt_line("住宅代理: ", secret=True)
        if not answer and old:
            result = dict(old)
            break
        try:
            result = parse_proxy_input(answer)
            result["udp"] = old.get("udp", False)
            break
        except UserError as error:
            print(f"格式有误：{error}。请重新输入。", flush=True)
    default = old.get("expected_exit_ip", "")
    while True:
        answer = prompt_line("预期出口 IP（可选，回车" + (f"保留 {default}，输入 - 清空" if default else "跳过")
                             + "；不一定等于代理地址）: ").strip()
        result["expected_exit_ip"] = "" if answer == "-" else answer or default
        try:
            return validate_settings(result)
        except UserError as error:
            print(f"格式有误：{error}。请重新输入。", flush=True)


def subscription_provider(source):
    providers = source.get("proxy-providers", {})
    if set(providers) != {"sub"} or source.get("proxies"):
        raise UserError("住宅模式要求 install.sh 创建的单个 sub 订阅；暂不支持合并自定义节点/多个 provider")
    provider = providers["sub"]
    if not isinstance(provider, dict) or provider.get("type") != "http":
        raise UserError("sub 必须是 HTTP 类型的 Clash YAML 订阅")
    if any(provider.get(key) for key in ("override", "filter", "exclude-filter", "exclude-type", "proxy")):
        raise UserError("sub 包含自定义覆盖、筛选或下载代理，请先移除这些设置")
    url = provider.get("url", "")
    if not isinstance(url, str) or urlsplit(url).scheme not in ("http", "https"):
        raise UserError("订阅链接必须是 HTTP/HTTPS 地址")
    return provider


def parse_nodes(data):
    try:
        value = yaml.safe_load(data)
    except (yaml.YAMLError, UnicodeError):
        raise UserError("订阅不是有效的 Clash YAML（不支持 Base64/URI 订阅）") from None
    if not isinstance(value, dict) or not isinstance(value.get("proxies"), list):
        raise UserError("订阅必须含有 proxies 列表；请使用 Clash/Mihomo 格式")
    nodes, seen = [], set()
    for node in value["proxies"]:
        if not isinstance(node, dict) or not isinstance(node.get("type"), str):
            raise UserError("订阅含有无效节点")
        name = node.get("name")
        if not isinstance(name, str) or not name.strip() or any(ord(c) < 32 for c in name):
            raise UserError("节点名称为空或含控制字符")
        if node["type"].lower() in ("direct", "reject", "pass", "compatible", "dns") or "如果你看到" in name:
            continue
        if name in RESERVED or name.startswith(PREFIX) or name in seen:
            raise UserError("订阅包含重复名称或住宅模式保留名称，请修改订阅节点名")
        if node.get("dialer-proxy"):
            raise UserError("订阅节点已有 dialer-proxy，请先检查原有代理链")
        seen.add(name)
        nodes.append(copy.deepcopy(node))
    if not nodes:
        raise UserError("订阅没有可用的机场节点，保留原配置")
    return nodes


def fetch_nodes(source, subscription_file=None):
    provider = subscription_provider(source)
    if subscription_file:
        data = Path(subscription_file).read_bytes()
    else:
        headers = {"User-Agent": "clash.meta"}
        for key, value in provider.get("header", {}).items():
            headers[key] = ", ".join(value) if isinstance(value, list) else str(value)
        # Bootstrap subscription downloads must not depend on a working residential exit.
        request = Request(provider["url"], headers=headers)
        try:
            with build_opener(ProxyHandler({})).open(request, timeout=30) as response:
                data = response.read(MAX_SUBSCRIPTION + 1)
        except (URLError, TimeoutError, OSError, ValueError):
            raise UserError("订阅下载失败；原配置未变。也可通过 --subscription-file 导入已下载的 Clash YAML") from None
    if len(data) > MAX_SUBSCRIPTION:
        raise UserError("订阅超过 16 MiB，拒绝加载")
    return parse_nodes(data)


def build_config(source, settings, nodes):
    subscription_provider(source)
    if source.get("listeners") or source.get("tunnels") or source.get("tun", {}).get("enable"):
        raise UserError("本工具管理显式代理入口；已有自定义 listeners/tunnels/TUN 的配置需单独适配")
    config = copy.deepcopy(source)
    for key in ("proxy-providers", "rule-providers", "sub-rules", "sniffer"):
        config.pop(key, None)
    names = [node["name"] for node in nodes]
    proxies = []
    for node in nodes:
        name = node["name"]
        proxies.append({"name": name, "type": "socks5", "server": settings["server"],
                        "port": settings["port"], "username": settings["username"],
                        "password": settings["password"], "udp": settings["udp"],
                        "dialer-proxy": PREFIX + name})
        raw = copy.deepcopy(node)
        raw["name"] = PREFIX + name
        proxies.append(raw)
    config["proxies"] = proxies
    config["proxy-groups"] = [
        {"name": "PROXY", "type": "select", "proxies": names},
        {"name": "AUTO", "type": "url-test", "proxies": names,
         "url": "https://www.gstatic.com/generate_204", "interval": 300},
        {"name": "GLOBAL", "type": "select", "proxies": ["PROXY", "AUTO"] + names},
    ]
    config["mode"] = "rule"
    config["ipv6"] = False
    config["profile"] = {"store-selected": False, "store-fake-ip": False}
    config["rules"] = ([] if settings["udp"] else ["NETWORK,UDP,REJECT"]) + ["MATCH,PROXY"]
    # No OS DNS/TUN changes. Only resolutions handled by mihomo use this DNS policy.
    config["dns"] = {
        "enable": True, "ipv6": False, "enhanced-mode": "redir-host",
        "prefer-h3": False, "respect-rules": False,
        "default-nameserver": ["https://223.5.5.5/dns-query"],
        "proxy-server-nameserver": ["https://223.5.5.5/dns-query#DIRECT",
                                    "https://223.6.6.6/dns-query#DIRECT"],
        "nameserver": ["https://1.1.1.1/dns-query#PROXY", "https://1.0.0.1/dns-query#PROXY"],
        "fallback": [],
    }
    return config


class Controller:
    def __init__(self, config):
        address = config.get("external-controller", "")
        try:
            parsed = urlsplit("http://" + address)
            if parsed.hostname != "localhost" and not ipaddress.ip_address(parsed.hostname).is_loopback:
                raise ValueError
            if not parsed.port or parsed.username or parsed.path:
                raise ValueError
        except (ValueError, TypeError):
            raise UserError("external-controller 必须监听本机回环地址及端口") from None
        self.url = "http://" + address
        self.secret = config.get("secret", "")
        self.opener = build_opener(ProxyHandler({}))

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = Request(self.url + path, data=data, method=method,
                          headers={"Authorization": "Bearer " + self.secret, "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=15) as response:
                result = response.read()
            return json.loads(result) if result else None
        except (URLError, OSError, ValueError):
            raise UserError(f"mihomo 控制接口调用失败：{method} {path.split('?')[0]}（检查服务及密钥）") from None

    def select(self, group, name):
        self.call("PUT", "/proxies/" + quote(group, safe=""), {"name": name})


def running(root):
    """Find only this installation, including systemd services without a PID file."""
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            args = (entry / "cmdline").read_bytes().decode().split("\0")
            if Path(args[0]).name != "mihomo" or "-d" not in args:
                continue
            directory = Path(args[args.index("-d") + 1])
            if not directory.is_absolute():
                directory = (entry / "cwd").resolve() / directory
            if directory.resolve() == root:
                return True
        except (OSError, UnicodeError, IndexError):
            continue
    return False


def start(root):
    """Start this installation as the current user and wait for its controller."""
    config = read_yaml(root / "config.yaml")
    controller = Controller(config)
    if running(root):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                controller.call("GET", "/version")
                print("mihomo 已运行，沿用现有进程。")
                return
            except UserError:
                time.sleep(0.1)
        raise UserError("已有 mihomo 进程，但控制接口不可用；请检查日志及控制密钥")
    validate_config(root, dump_yaml(config))
    address = urlsplit(controller.url)
    listeners = [("127.0.0.1", config.get(key)) for key in ("mixed-port", "port", "socks-port")]
    listeners.append((address.hostname, address.port))
    for host, port in listeners:
        if not port:
            continue
        try:
            with socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET) as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind((host, port))
        except OSError:
            raise UserError(f"监听端口 {host}:{port} 已被占用或无法绑定；未启动新进程") from None
    log_path = root / "run/mihomo.log"
    with log_path.open("ab") as log:
        log_path.chmod(0o600)
        process = subprocess.Popen([str(root / "bin/mihomo"), "-d", str(root)],
                                   cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True)
    try:
        atomic_write(root / "run/mihomo.pid", str(process.pid) + "\n")
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            try:
                controller.call("GET", "/version")
                # Give the process time to report startup failures as well.
                time.sleep(0.2)
                if process.poll() is None:
                    print(f"mihomo 已启动（PID {process.pid}）。")
                    return
            except UserError:
                pass
            time.sleep(0.1)
        raise UserError(f"mihomo 启动未通过检查，请查看 {log_path}")
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        (root / "run/mihomo.pid").unlink(missing_ok=True)
        raise


def validate_config(root, text):
    with tempfile.TemporaryDirectory(prefix=".residential-check-", dir=root) as directory:
        path = Path(directory) / "config.yaml"
        atomic_write(path, text)
        result = subprocess.run([str(root / "bin/mihomo"), "-t", "-d", str(root), "-f", str(path)],
                                capture_output=True, timeout=30)
        if result.returncode:
            log = root / "run/residential-validation.log"
            atomic_write(log, result.stdout + result.stderr)
            raise UserError(f"mihomo 配置校验失败；详情保存在私有日志 {log}，原配置未变")


def apply_config(root, config, files):
    """Validate before replacing files; roll back both disk and runtime on failure."""
    text = dump_yaml(config)
    validate_config(root, text)
    files = {**files, "config.yaml": text.encode()}
    previous = {name: (root / name).read_bytes() if (root / name).exists() else None for name in files}
    old_config = read_yaml(root / "config.yaml")
    controller = Controller(old_config) if running(root) else None
    selections = {}
    old_mode = old_config.get("mode", "rule")
    if controller:
        old_mode = controller.call("GET", "/configs")["mode"]
        selections = {name: p.get("now") for name, p in controller.call("GET", "/proxies")["proxies"].items()
                      if p.get("type") == "Selector"}
    # No reload for an unchanged periodic refresh, preserving active connections.
    changed = previous["config.yaml"] != files["config.yaml"] or (controller is not None and old_mode != config.get("mode", "rule"))
    attempted_reload = False
    try:
        for name, data in files.items():
            atomic_write(root / name, data)
        if controller and changed:
            attempted_reload = True
            controller.call("PUT", "/configs?force=true", {"path": str(root / "config.yaml")})
            controller.call("PATCH", "/configs", {"mode": config.get("mode", "rule")})
            for group in config.get("proxy-groups", []):
                selected = selections.get(group["name"])
                if group["type"] == "select" and selected in group.get("proxies", []):
                    controller.select(group["name"], selected)
            # Existing raw-airport connections must not survive first activation.
            controller.call("DELETE", "/connections")
    except BaseException:
        for name, data in previous.items():
            if data is None:
                (root / name).unlink(missing_ok=True)
            else:
                atomic_write(root / name, data)
        if controller and attempted_reload:
            try:
                controller.call("PUT", "/configs?force=true", {"path": str(root / "config.yaml")})
                controller.call("PATCH", "/configs", {"mode": old_mode})
                for group, selected in selections.items():
                    if selected:
                        controller.select(group, selected)
            except UserError:
                print("[WARN] 磁盘配置已恢复，但运行配置回滚失败；请重启本安装目录的 mihomo。", file=sys.stderr)
        raise
    print("配置已校验并加载。" if controller and changed else
          "配置未变化，保留现有连接。" if not changed else "配置已校验并保存；下次启动 mihomo 生效。", flush=True)


def copy_runtime_tool(root):
    destination = root / "residential.py"
    if Path(__file__).resolve() != destination.resolve():
        atomic_write(destination, Path(__file__).read_bytes())
    # Cron does not inherit an activated Conda/venv environment. Pin the working
    # interpreter just as the systemd unit does; do not assume /usr/bin/python3.
    launcher = root / "residential-refresh.sh"
    atomic_write(launcher,
                 '#!/usr/bin/env bash\nset -euo pipefail\n'
                 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
                 f'exec {shlex.quote(sys.executable)} "$SCRIPT_DIR/residential.py" '
                 '--install-dir "$SCRIPT_DIR" refresh "$@"\n')
    launcher.chmod(0o700)


def update(root, args):
    state_path = root / SETTINGS
    configured = (root / SOURCE).exists()
    if args.command != "configure" and not configured:
        raise UserError("尚未启用住宅模式，请先运行 configure")
    source = read_yaml(root / SOURCE if configured else root / "config.yaml")
    settings = read_settings(state_path) if state_path.exists() else {}
    if args.command == "configure":
        settings = read_settings(args.settings_file) if args.settings_file else prompt_settings(settings)
    settings = validate_settings(settings)
    if args.command == "subscription":
        url = input("新的 Clash 订阅链接: ").strip()
        if not url:
            raise UserError("订阅链接不能为空")
        source["proxy-providers"]["sub"]["url"] = url
    nodes = fetch_nodes(source, args.subscription_file)
    config = build_config(source, settings, nodes)
    files = {SOURCE: dump_yaml(source).encode(), SETTINGS: (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode(),
             CACHE: dump_yaml({"proxies": nodes}).encode()}
    if not configured:
        files["config.before-residential.yaml"] = (root / "config.yaml").read_bytes()
    apply_config(root, config, files)
    copy_runtime_tool(root)
    print(f"住宅模式：{len(nodes)} 条机场 → 住宅 SOCKS5 链；UDP {'启用（需供应商支持）' if settings['udp'] else '拒绝'}。")


def check_exit(config, settings, url):
    port = config.get("mixed-port") or config.get("port")
    if not port:
        raise UserError("配置没有 HTTP/mixed 代理端口")
    result = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--noproxy", "",
                             "--proxy", f"http://127.0.0.1:{port}", "--connect-timeout", "8",
                             "--max-time", "20", "--url", url], capture_output=True, timeout=25)
    if result.returncode:
        raise UserError("出口请求失败（不会改用直连）")
    try:
        actual = str(ipaddress.ip_address(result.stdout.decode().strip()))
    except (ValueError, UnicodeError):
        raise UserError("检测服务没有返回纯文本 IP") from None
    expected = settings.get("expected_exit_ip")
    if expected and actual != expected:
        raise UserError(f"出口不匹配：实际 {actual}，预期 {expected}")
    return actual


def verify(root, args):
    settings = read_settings(root / SETTINGS)
    config = read_yaml(root / "config.yaml")
    controller = Controller(config)
    if controller.call("GET", "/configs")["mode"] != "rule":
        raise UserError("出口验证要求 rule 模式；请在控制面板切回 rule 后重试")
    groups = controller.call("GET", "/proxies")["proxies"]
    group = groups["PROXY"]
    selected = group["now"]
    choices = group["all"] if args.all else [selected]
    failures = 0
    try:
        for name in choices:
            if args.all:
                controller.select("PROXY", name)
            try:
                actual = check_exit(config, settings, args.url)
                print(f"[OK] {name}: {actual}", flush=True)
            except UserError as error:
                failures += 1
                print(f"[FAIL] {name}: {error}", flush=True)
    finally:
        if args.all:
            controller.select("PROXY", selected)
    if not settings.get("expected_exit_ip"):
        print("未配置 expected_exit_ip，以上仅验证连通性；请填入供应商分配的出口 IP 后再次验证。")
    if failures:
        raise UserError(f"{failures}/{len(choices)} 条链路未通过验证")


def unit_name(root):
    return "mihomo-residential-" + hashlib.sha256(str(root).encode()).hexdigest()[:12]


def unit_quote(value, command=True):
    value = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    return '"' + (value.replace('$', '$$') if command else value) + '"'


def timer(root, install):
    name = unit_name(root)
    directory = Path.home() / ".config/systemd/user"
    if not shutil.which("systemctl"):
        raise UserError("未找到 systemctl；请手动运行 refresh，或用 cron 定时执行")
    if install:
        if not (root / SOURCE).exists():
            raise UserError("请先 configure，再启用订阅更新定时器")
        copy_runtime_tool(root)
        directory.mkdir(parents=True, exist_ok=True)
        atomic_write(directory / (name + ".service"),
                     "[Unit]\nDescription=Refresh mihomo residential chains\n\n[Service]\nType=oneshot\nUMask=0077\n"
                     f"ExecStart={unit_quote(sys.executable)} {unit_quote(root / 'residential.py')} "
                     f"--install-dir {unit_quote(root)} refresh\n")
        atomic_write(directory / (name + ".timer"),
                     "[Unit]\nDescription=Hourly mihomo residential subscription refresh\n\n[Timer]\n"
                     "OnActiveSec=5min\nOnUnitActiveSec=1h\n\n[Install]\nWantedBy=timers.target\n")
        commands = [["daemon-reload"], ["enable", "--now", name + ".timer"]]
    else:
        commands = [["disable", "--now", name + ".timer"]]
    for command in commands:
        result = subprocess.run(["systemctl", "--user"] + command, capture_output=True, timeout=30)
        if result.returncode:
            raise UserError("用户 systemd 不可用或定时器操作失败；可手动 refresh，或配置 cron。详见 README。")
    print(f"定时器 {'已启用（每小时）' if install else '已停用'}：{name}.timer")


def cron(root, install):
    if not shutil.which("crontab"):
        raise UserError("没有可用的用户 crontab")
    if "\n" in str(root) or "\r" in str(root):
        raise UserError("crontab 不支持包含换行的安装路径")
    env = {**os.environ, "LC_ALL": "C"}
    result = subprocess.run(["crontab", "-l"], env=env, capture_output=True, text=True, timeout=10)
    if result.returncode and not (result.returncode == 1 and "no crontab for" in result.stderr.lower()):
        raise UserError("无法读取用户 crontab，可能被服务器策略禁止")
    marker = "# " + unit_name(root)
    lines = [line for line in result.stdout.splitlines() if not line.endswith(marker)]
    if install:
        if not (root / SOURCE).exists():
            raise UserError("请先配置住宅模式")
        copy_runtime_tool(root)
        log = root / "run/residential-refresh.log"
        log.touch(mode=0o600, exist_ok=True)
        log.chmod(0o600)
        # Cron interprets percent signs even inside shell quotes.
        command = (f"/bin/bash {shlex.quote(str(root / 'residential-refresh.sh'))} "
                   f">> {shlex.quote(str(log))} 2>&1").replace("%", "\\%")
        lines.append(f"0 * * * * {command} {marker}")
    result = subprocess.run(["crontab", "-"], input="\n".join(lines) + "\n", env=env,
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise UserError("无法写入用户 crontab")
    print(f"用户 cron {'已启用（每小时）' if install else '已停用'}。")


def main():
    parser = argparse.ArgumentParser(description="固定住宅 SOCKS5 出口；不接管系统 TUN/路由")
    default = os.environ.get("INSTALL_DIR")
    if not default:
        here = Path(__file__).resolve().parent
        default = str(here if (here / "bin/mihomo").is_file() else Path.home() / "tools/mihomo")
    parser.add_argument("--install-dir", default=default, help="mihomo 安装目录，也可用 INSTALL_DIR")
    sub = parser.add_subparsers(dest="command", required=True)
    child = sub.add_parser("collect-settings", help="供安装入口提前交互收集参数，无需已有内核")
    child.add_argument("--output", required=True, help="安装脚本管理的私有临时文件")
    for command in ("configure", "refresh", "subscription"):
        child = sub.add_parser(command)
        child.add_argument("--subscription-file", help="离线导入 Clash YAML；不会覆盖已保存的远程订阅 URL")
        if command == "configure":
            child.add_argument("--settings-file", help="从私有 JSON 文件导入住宅参数，否则交互输入")
    child = sub.add_parser("verify")
    child.add_argument("--all", action="store_true", help="逐个切换 PROXY 并验证，结束恢复选择；会影响同时使用的应用")
    child.add_argument("--url", default="https://api.ipify.org", help="返回纯文本 IP 的检测地址")
    sub.add_parser("timer-install")
    sub.add_parser("timer-remove")
    sub.add_parser("cron-install")
    sub.add_parser("cron-remove")
    sub.add_parser("start")
    sub.add_parser("status")
    args = parser.parse_args()
    root = Path(args.install_dir).expanduser().resolve()
    os.umask(0o077)
    if args.command == "collect-settings":
        old = read_settings(root / SETTINGS) if (root / SETTINGS).is_file() else {}
        settings = prompt_settings(old)
        atomic_write(Path(args.output), json.dumps(settings, ensure_ascii=False, indent=2) + "\n")
        return
    if not (root / "config.yaml").is_file() or not (root / "bin/mihomo").is_file():
        raise UserError("安装目录缺少 config.yaml 或 bin/mihomo；请先安装或指定 --install-dir")
    (root / "run").mkdir(exist_ok=True)
    with (root / "run/residential.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise UserError("另一个住宅配置操作正在进行，请稍后重试") from None
        if args.command in ("configure", "refresh", "subscription"):
            update(root, args)
        elif args.command == "verify":
            verify(root, args)
        elif args.command.startswith("timer-"):
            timer(root, args.command == "timer-install")
        elif args.command.startswith("cron-"):
            cron(root, args.command == "cron-install")
        elif args.command == "start":
            start(root)
        else:
            enabled = (root / SOURCE).exists()
            print(f"住宅模式：{'已配置' if enabled else '未配置'}\n安装目录：{root}")
            if enabled:
                settings = read_settings(root / SETTINGS)
                nodes = read_yaml(root / "config.yaml").get("proxies", [])
                print(f"包装节点：{sum(p.get('dialer-proxy', '').startswith(PREFIX) for p in nodes)}")
                print(f"预期出口：{settings.get('expected_exit_ip') or '未设置'}")
                print(f"定时器：{unit_name(root)}.timer（systemctl --user status 查看运行状态）")
                print("若安装时使用了 cron，可通过 crontab -l 查看相应任务。")


if __name__ == "__main__":
    try:
        main()
    except (UserError, OSError, subprocess.TimeoutExpired) as error:
        # Never print subprocess commands, subscription URLs or credential-bearing YAML.
        message = str(error) if isinstance(error, UserError) else "文件/进程操作失败，请检查目录权限、依赖和服务状态"
        print("[ERROR] " + message, file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\n操作已取消。", file=sys.stderr)
        sys.exit(130)
