"""Hermetic chain tests: all servers and upstream connections stay on loopback."""

import contextlib
import io
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))
import residential as r


def settings():
    return {"server": "127.0.0.1", "port": 1080, "username": "test-user",
            "password": "test: '\"\\&$ password", "udp": False, "expected_exit_ip": "127.0.0.3"}


def source():
    return {"mixed-port": 17890, "external-controller": "127.0.0.1:19090", "secret": "test-secret",
            "mode": "rule", "proxy-providers": {"sub": {"type": "http", "url": "https://example.invalid/sub"}},
            "proxy-groups": [{"name": "PROXY", "type": "select", "use": ["sub"]}],
            "rules": ["MATCH,PROXY"]}


def nodes():
    return [{"name": "香港 01", "type": "socks5", "server": "127.0.0.1", "port": 1081},
            {"name": "日本 02", "type": "socks5", "server": "127.0.0.1", "port": 1082}]


class ConfigTests(unittest.TestCase):
    def test_every_selectable_path_ends_at_residence(self):
        config = r.build_config(source(), settings(), nodes())
        proxies = {p["name"]: p for p in config["proxies"]}
        for group in config["proxy-groups"]:
            for name in group["proxies"]:
                self.assertNotIn(name, {"DIRECT", "REJECT"})
                self.assertFalse(name.startswith(r.PREFIX))
                if name in {"PROXY", "AUTO"}:
                    continue
                proxy = proxies[name]
                self.assertEqual(proxy["server"], settings()["server"])
                self.assertEqual(proxy["password"], settings()["password"])
                self.assertEqual(proxies[proxy["dialer-proxy"]]["port"], next(n["port"] for n in nodes() if n["name"] == name))
        self.assertEqual(config["rules"], ["NETWORK,UDP,REJECT", "MATCH,PROXY"])
        self.assertNotIn("proxy-providers", config)
        self.assertNotIn("listen", config["dns"])
        self.assertTrue(all(url.endswith("#PROXY") for url in config["dns"]["nameserver"]))

    def test_subscription_rejects_empty_duplicate_reserved_and_existing_chains(self):
        for entries in ([], [nodes()[0], nodes()[0]], [{**nodes()[0], "name": "GLOBAL"}],
                        [{**nodes()[0], "name": r.PREFIX + "raw"}],
                        [{**nodes()[0], "dialer-proxy": "other"}]):
            with self.subTest(entries=entries), self.assertRaises(r.UserError):
                r.parse_nodes(r.dump_yaml({"proxies": entries}))
        with self.assertRaises(r.UserError):
            r.parse_nodes("<html>not a subscription</html>")

    def test_full_subscription_rules_cannot_supply_a_bypass(self):
        value = {"proxies": nodes() + [{"name": "直连", "type": "direct"}],
                 "rules": ["MATCH,DIRECT"], "proxy-groups": [{"name": "PROXY", "proxies": ["DIRECT"]}]}
        clean = r.parse_nodes(r.dump_yaml(value))
        self.assertEqual(clean, nodes())
        self.assertEqual(r.build_config(source(), settings(), clean)["rules"][-1], "MATCH,PROXY")

    def test_settings_require_types_and_valid_ip(self):
        for change in ({"port": True}, {"port": "1080"}, {"udp": "false"},
                       {"expected_exit_ip": "not-an-ip"}, {"server": "socks5://host"}):
            with self.subTest(change=change), self.assertRaises(r.UserError):
                r.validate_settings({**settings(), **change})

    def test_compact_proxy_input_preserves_password_and_supports_hostnames_ipv6(self):
        password = "test:p@ss ' \"\\&$(literal) "
        for endpoint, host in (("192.0.2.10", "192.0.2.10"), ("proxy.example.com", "proxy.example.com"),
                               ("[2001:db8::1]", "2001:db8::1")):
            with self.subTest(endpoint=endpoint):
                value = r.parse_proxy_input(f"{endpoint}:1080@test-user:{password}")
                self.assertEqual(value["server"], host)
                self.assertEqual(value["port"], 1080)
                self.assertEqual(value["username"], "test-user")
                self.assertEqual(value["password"], password)
                self.assertEqual(value["expected_exit_ip"], "")
                self.assertFalse(value["udp"])
        for value in ("", "host:1080", "host:1080@user", "host:1080@:secret", "host:1080@user:",
                      "host:0@user:secret", "host:65536@user:secret", "host:abc@user:secret",
                      "socks5://host:1080@user:secret", "::1:1080@user:secret", "host:1080@user:secret\n"):
            with self.subTest(value=value), self.assertRaises(r.UserError) as error:
                r.parse_proxy_input(value)
            self.assertNotIn("secret", str(error.exception))

    def test_interactive_settings_retry_reuse_and_clear_expected_ip(self):
        compact = f"127.0.0.1:1080@{settings()['username']}:{settings()['password']}"
        with patch.object(r, "prompt_line", side_effect=["bad-input", compact, "invalid-ip", "127.0.0.3"]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(r.prompt_settings({}), settings())
        self.assertNotIn(settings()["password"], output.getvalue())
        self.assertIn("请重新输入", output.getvalue())
        with patch.object(r, "prompt_line", side_effect=["", ""]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(r.prompt_settings(settings()), settings())
        with patch.object(r, "prompt_line", side_effect=["", "-"]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(r.prompt_settings(settings())["expected_exit_ip"], "")

    def test_fetch_failure_does_not_expose_subscription_credentials(self):
        value = source()
        value["proxy-providers"]["sub"]["url"] = "https://example.invalid/sub?token=DO-NOT-PRINT"
        with patch.object(r, "build_opener") as opener:
            opener.return_value.open.side_effect = r.URLError(value["proxy-providers"]["sub"]["url"])
            with self.assertRaises(r.UserError) as error:
                r.fetch_nodes(value)
            self.assertNotIn("DO-NOT-PRINT", str(error.exception))

    def test_download_accepts_clash_yaml_and_ignores_environment_proxy(self):
        class Subscription(BaseHTTPRequestHandler):
            def do_GET(self):
                data = r.dump_yaml({"proxies": nodes(), "rules": ["MATCH,DIRECT"]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Subscription)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        try:
            value = source()
            value["proxy-providers"]["sub"]["url"] = f"http://127.0.0.1:{server.server_port}/sub"
            with patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1",
                                         "NO_PROXY": "", "no_proxy": ""}):
                self.assertEqual(r.fetch_nodes(value), nodes())
        finally:
            server.shutdown()
            server.server_close()

    def test_reload_failure_restores_disk_and_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = r.dump_yaml(source()).encode()
            r.atomic_write(root / "config.yaml", old)
            r.atomic_write(root / r.SETTINGS, b"previous-settings")
            calls = []

            class FakeController:
                failed = False

                def __init__(self, config):
                    pass

                def call(self, method, path, body=None):
                    calls.append((method, path, body))
                    if method == "GET":
                        return {"mode": "global"} if path == "/configs" else {"proxies": {}}
                    if method == "PUT" and not self.failed:
                        self.failed = True
                        raise r.UserError("simulated reload failure")

            with patch.object(r, "running", return_value=True), patch.object(r, "validate_config"), \
                    patch.object(r, "Controller", FakeController), self.assertRaises(r.UserError):
                r.apply_config(root, r.build_config(source(), settings(), nodes()),
                               {r.SETTINGS: b"new-settings", r.SOURCE: b"new-source"})
            self.assertEqual((root / "config.yaml").read_bytes(), old)
            self.assertEqual((root / r.SETTINGS).read_bytes(), b"previous-settings")
            self.assertFalse((root / r.SOURCE).exists())
            self.assertEqual(sum(method == "PUT" for method, _, _ in calls), 2)

    def test_start_refuses_occupied_port_before_spawning(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            root = Path(directory)
            config = source()
            config["mixed-port"] = occupied.getsockname()[1]
            (root / "config.yaml").write_text(r.dump_yaml(config))
            with patch.object(r, "running", return_value=False), patch.object(r, "validate_config"), \
                    patch.object(r.subprocess, "Popen") as spawn, self.assertRaises(r.UserError):
                r.start(root)
            spawn.assert_not_called()

    def test_cron_permission_error_never_replaces_other_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(r.shutil, "which", return_value="/usr/bin/crontab"), \
                    patch.object(r.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="permission denied")) as run, \
                    self.assertRaises(r.UserError):
                r.cron(Path(directory), True)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0], ["crontab", "-l"])


def receive(stream, length):
    data = b""
    while len(data) < length:
        part = stream.recv(length - len(data))
        if not part:
            raise EOFError
        data += part
    return data


class SocksHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            client = self.request
            client.settimeout(5)
            version, count = receive(client, 2)
            assert version == 5
            receive(client, count)
            if self.server.auth:
                client.sendall(b"\x05\x02")
                version, length = receive(client, 2)
                user = receive(client, length).decode()
                password = receive(client, receive(client, 1)[0]).decode()
                valid = (user, password) == self.server.auth
                client.sendall(b"\x01\x00" if valid else b"\x01\x01")
                if not valid:
                    return
            else:
                client.sendall(b"\x05\x00")
            version, command, _, kind = receive(client, 4)
            if kind == 1:
                host = socket.inet_ntoa(receive(client, 4))
            elif kind == 3:
                host = receive(client, receive(client, 1)[0]).decode()
            else:
                return
            port = struct.unpack("!H", receive(client, 2))[0]
            # Prevent AUTO health checks or DNS from contacting the public network.
            if command != 1 or not host.startswith("127.") or not self.server.enabled:
                client.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
                return
            self.server.targets.append((host, port))
            with socket.socket() as upstream:
                upstream.settimeout(5)
                upstream.bind((self.server.egress, 0))
                upstream.connect((host, port))
                client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                while True:
                    ready, _, _ = select.select([client, upstream], [], [], 5)
                    if not ready:
                        return
                    for stream in ready:
                        data = stream.recv(65536)
                        if not data:
                            return
                        (upstream if stream is client else client).sendall(data)
        except (OSError, EOFError, AssertionError):
            return


class SocksServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, egress, auth=None):
        super().__init__(("127.0.0.1", 0), SocksHandler)
        self.egress, self.auth, self.targets, self.enabled = egress, auth, [], True


class ExitHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.peers.append(self.client_address[0])
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def free_port():
    with socket.socket() as stream:
        stream.bind(("127.0.0.1", 0))
        return stream.getsockname()[1]


class LiveChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get("MIHOMO_TEST_BINARY", PROJECT.parent / "mihomo/bin/mihomo")).resolve()
        if not cls.binary.is_file():
            raise unittest.SkipTest("设置 MIHOMO_TEST_BINARY 可运行真实 mihomo 集成测试")

    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="mihomo-test-")))
        self.servers = []
        credentials = settings()
        self.residence = self.serve(SocksServer("127.0.0.3", (credentials["username"], credentials["password"])))
        self.airports = [self.serve(SocksServer("127.0.0.2")), self.serve(SocksServer("127.0.0.4"))]
        self.target = self.serve(ThreadingHTTPServer(("127.0.0.1", 0), ExitHandler))
        self.target.peers = []
        self.url = f"http://127.0.0.1:{self.target.server_port}/ip"
        credentials["port"] = self.residence.server_address[1]
        self.settings = credentials
        self.credentials = self.root / "input.json"
        self.credentials.write_text(json.dumps(credentials))
        self.nodes = nodes()
        for node, server in zip(self.nodes, self.airports):
            node["port"] = server.server_address[1]
        self.subscription = self.root / "input.yaml"
        self.subscription.write_text(r.dump_yaml({"proxies": self.nodes}))
        config = source()
        config["mixed-port"] = free_port()
        config["external-controller"] = f"127.0.0.1:{free_port()}"
        (self.root / "bin").mkdir()
        (self.root / "bin/mihomo").symlink_to(self.binary)
        (self.root / "config.yaml").write_text(r.dump_yaml(config))
        self.cli("configure", "--settings-file", str(self.credentials), "--subscription-file", str(self.subscription))
        self.config = r.read_yaml(self.root / "config.yaml")
        log = self.stack.enter_context((self.root / "test.log").open("w"))
        self.process = subprocess.Popen([str(self.root / "bin/mihomo"), "-d", str(self.root)], stdout=log, stderr=log)
        self.stack.callback(self.stop_process)
        self.controller = r.Controller(self.config)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.controller.call("GET", "/version")
                break
            except r.UserError:
                time.sleep(0.05)
        else:
            self.fail("isolated mihomo did not start")

    def serve(self, server):
        self.servers.append(server)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.stack.callback(server.server_close)
        self.stack.callback(server.shutdown)
        return server

    def stop_process(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

    def cli(self, *args, success=True):
        result = subprocess.run([sys.executable, str(PROJECT / "residential.py"), "--install-dir", str(self.root), *args],
                                capture_output=True, text=True, timeout=30,
                                env={**os.environ, "NO_PROXY": "*", "no_proxy": "*"})
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertNotIn(self.settings["password"], result.stdout + result.stderr)
        return result

    def test_both_airports_have_identical_residential_exit_and_private_state(self):
        self.cli("verify", "--all", "--url", self.url)
        self.assertEqual(self.target.peers, ["127.0.0.3", "127.0.0.3"])
        for airport in self.airports:
            self.assertIn(("127.0.0.1", self.residence.server_address[1]), airport.targets)
            self.assertTrue(all(port == self.residence.server_address[1] for _, port in airport.targets))
        groups = self.controller.call("GET", "/proxies")["proxies"]
        for name in ("PROXY", "AUTO", "GLOBAL"):
            self.assertNotIn("DIRECT", groups[name]["all"])
            self.assertFalse(any(choice.startswith(r.PREFIX) for choice in groups[name]["all"]))
        for name in (r.SETTINGS, r.SOURCE, r.CACHE, "config.yaml", "config.before-residential.yaml"):
            self.assertEqual((self.root / name).stat().st_mode & 0o777, 0o600)

    def test_residential_failure_never_falls_back_to_airport_or_direct(self):
        self.residence.enabled = False
        self.cli("verify", "--all", "--url", self.url, success=False)
        self.assertEqual(self.target.peers, [])
        self.assertEqual(self.controller.call("GET", "/proxies/PROXY")["now"], self.nodes[0]["name"])

    def test_bad_update_preserves_working_configuration(self):
        before = {name: (self.root / name).read_bytes() for name in (r.SOURCE, r.SETTINGS, r.CACHE, "config.yaml")}
        self.subscription.write_text("proxies: []\n")
        self.cli("refresh", "--subscription-file", str(self.subscription), success=False)
        for name, content in before.items():
            self.assertEqual((self.root / name).read_bytes(), content)
        self.subscription.write_text(r.dump_yaml({"proxies": [{**self.nodes[0], "type": "not-a-protocol"}]}))
        self.cli("refresh", "--subscription-file", str(self.subscription), success=False)
        for name, content in before.items():
            self.assertEqual((self.root / name).read_bytes(), content)
        self.cli("verify", "--url", self.url)

    def test_refresh_preserves_choice_and_wraps_new_nodes(self):
        self.controller.select("PROXY", self.nodes[1]["name"])
        more = {**self.nodes[0], "name": "新增节点"}
        self.subscription.write_text(r.dump_yaml({"proxies": self.nodes + [more]}))
        self.cli("refresh", "--subscription-file", str(self.subscription))
        group = self.controller.call("GET", "/proxies/PROXY")
        self.assertEqual(group["now"], self.nodes[1]["name"])
        self.assertIn("新增节点", group["all"])
        self.cli("verify", "--all", "--url", self.url)
        self.assertEqual(self.target.peers, ["127.0.0.3"] * 3)

    def test_expected_exit_mismatch_is_failure(self):
        value = {**self.settings, "expected_exit_ip": "127.0.0.99"}
        (self.root / r.SETTINGS).write_text(json.dumps(value))
        result = self.cli("verify", "--url", self.url, success=False)
        self.assertIn("出口不匹配", result.stdout)

    def test_global_selection_also_uses_residential_exit(self):
        self.controller.call("PATCH", "/configs", {"mode": "global"})
        for node in self.nodes:
            self.controller.select("GLOBAL", node["name"])
            self.assertEqual(r.check_exit(self.config, self.settings, self.url), "127.0.0.3")

    def test_business_udp_is_blocked(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as target, \
                socket.create_connection(("127.0.0.1", self.config["mixed-port"]), timeout=2) as tcp:
            target.bind(("127.0.0.1", 0))
            target.settimeout(0.25)
            tcp.sendall(b"\x05\x01\x00")
            self.assertEqual(receive(tcp, 2), b"\x05\x00")
            tcp.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            version, result, _, kind = receive(tcp, 4)
            self.assertEqual((version, result, kind), (5, 0, 1))
            host = socket.inet_ntoa(receive(tcp, 4))
            port = struct.unpack("!H", receive(tcp, 2))[0]
            if host == "0.0.0.0":
                host = "127.0.0.1"
            packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", target.getsockname()[1]) + b"must-not-arrive"
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.sendto(packet, (host, port))
                with self.assertRaises(socket.timeout):
                    target.recvfrom(1024)

    def test_refresh_restores_rule_mode_even_when_file_is_unchanged(self):
        self.controller.call("PATCH", "/configs", {"mode": "direct"})
        self.cli("refresh", "--subscription-file", str(self.subscription))
        self.assertEqual(self.controller.call("GET", "/configs")["mode"], "rule")
        self.cli("verify", "--url", self.url)


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get("MIHOMO_TEST_BINARY", PROJECT.parent / "mihomo/bin/mihomo")).resolve()
        if not cls.binary.is_file():
            raise unittest.SkipTest("安装集成测试需要 MIHOMO_TEST_BINARY")

    def test_fresh_install_and_failed_residential_setup(self):
        residence = SocksServer("127.0.0.3", (settings()["username"], settings()["password"]))
        airports = [SocksServer("127.0.0.2"), SocksServer("127.0.0.4")]
        target = ThreadingHTTPServer(("127.0.0.1", 0), ExitHandler)
        target.peers = []
        subscription_nodes = nodes()
        for node, airport in zip(subscription_nodes, airports):
            node["port"] = airport.server_address[1]
        for service in [residence, *airports, target]:
            threading.Thread(target=service.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
            self.addCleanup(service.server_close)
            self.addCleanup(service.shutdown)
        private_settings = {**settings(), "port": residence.server_address[1]}

        class Subscription(BaseHTTPRequestHandler):
            def do_GET(self):
                data = r.dump_yaml({"proxies": subscription_nodes}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Subscription)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory(prefix="mihomo-install-test-") as directory:
            root = Path(directory)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            curl = fake_bin / "curl"
            # Exercise the real installer while serving the kernel from a local fixture.
            curl.write_text('''#!/usr/bin/env python3
import gzip, os, pathlib, sys
args = sys.argv[1:]
if "-o" in args:
    with gzip.open(args[args.index("-o") + 1], "wb", compresslevel=1) as stream:
        stream.write(pathlib.Path(os.environ["MIHOMO_TEST_BINARY"]).read_bytes())
elif any("api.github.com" in arg for arg in args):
    print('{"tag_name":"v1.19.23"}')
elif "--proxy" in args:
    os.execv(os.environ["MIHOMO_REAL_CURL"], [os.environ["MIHOMO_REAL_CURL"]] + args)
else:
    print("ok")
''')
            curl.chmod(0o700)
            systemctl = fake_bin / "systemctl"
            systemctl.write_text("#!/bin/sh\nexit 1\n")
            systemctl.chmod(0o700)
            crontab = fake_bin / "crontab"
            crontab.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
path = pathlib.Path(os.environ["MIHOMO_TEST_CRONTAB"])
if sys.argv[1] == "-l":
    print(path.read_text(), end="")
else:
    path.write_text(sys.stdin.read())
''')
            crontab.chmod(0o700)
            cron_file = root / "crontab.txt"
            cron_file.write_text("15 3 * * * /bin/true # existing-user-task\n")
            user_home = root / "home"
            user_home.mkdir()
            input_tmp = root / "input-tmp"
            input_tmp.mkdir()
            credentials = root / "private.json"
            env = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
                   "MIHOMO_TEST_BINARY": str(self.binary), "RESIDENTIAL_SETTINGS_FILE": str(credentials),
                   "MIHOMO_PYTHON": sys.executable, "HOME": str(user_home), "TMPDIR": str(input_tmp),
                   "MIHOMO_VERIFY_URL": f"http://127.0.0.1:{target.server_port}/ip",
                   "MIHOMO_REAL_CURL": shutil.which("curl"), "MIHOMO_TEST_CRONTAB": str(cron_file)}
            interactive_env = {key: value for key, value in env.items() if key != "RESIDENTIAL_SETTINGS_FILE"}
            compact = (f"{private_settings['server']}:{private_settings['port']}@"
                       f"{private_settings['username']}:{private_settings['password']}")
            # Cancelling at the credential prompt leaves no installation or private temporary files.
            cancelled = root / "cancelled-server"
            result = subprocess.run(["bash", str(PROJECT / "install.sh")], input=f"{cancelled}\ny\n",
                                    text=True, capture_output=True, env=interactive_env, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(cancelled.exists())
            self.assertEqual(list(input_tmp.glob("mihomo-residential.*")), [])
            for valid in (True, False):
                with self.subTest(valid=valid):
                    destination = root / ("server with spaces" if valid else "failed-server")
                    if not valid:
                        credentials.write_text(json.dumps({**private_settings, "port": "invalid"}))
                    answers = [str(destination)]
                    if valid:
                        answers += ["y", "bad-format", compact, private_settings["expected_exit_ip"]]
                    answers += [f"http://127.0.0.1:{server.server_port}/sub", str(free_port()),
                                str(free_port()), "https://download.invalid/", "y", "n", "y"]
                    result = subprocess.run(["bash", str(PROJECT / "install.sh")], input="\n".join(answers) + "\n",
                                            text=True, capture_output=True, env=interactive_env if valid else env, timeout=30)
                    pid_path = destination / "run/mihomo.pid"
                    if pid_path.exists():
                        pid = int(pid_path.read_text())

                        def stop(pid=pid, destination=destination):
                            try:
                                args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
                                if os.fsencode(destination) in args:
                                    os.kill(pid, signal.SIGTERM)
                            except (ProcessLookupError, FileNotFoundError):
                                pass

                        self.addCleanup(stop)
                    self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
                    self.assertNotIn(settings()["password"], result.stdout + result.stderr)
                    self.assertEqual(list(input_tmp.glob("mihomo-residential.*")), [])
                    if valid:
                        self.assertFalse(credentials.exists())
                        self.assertLess(result.stdout.index("住宅参数已接收"), result.stdout.index("正在获取 mihomo 最新版本号"))
                        self.assertEqual(r.read_settings(destination / r.SETTINGS), private_settings)
                        self.assertEqual((destination / r.SETTINGS).stat().st_mode & 0o777, 0o600)
                        config = r.read_yaml(destination / "config.yaml")
                        self.assertNotIn("proxy-providers", config)
                        self.assertEqual(len(config["proxies"]), 4)
                        self.assertTrue((destination / "residential.py").is_file())
                        self.assertEqual(target.peers[-1], "127.0.0.3")
                        self.assertIn("用户 crontab", result.stdout)
                        self.assertIn("existing-user-task", cron_file.read_text())
                        self.assertEqual(cron_file.read_text().count("# " + r.unit_name(destination)), 1)
                        terminal_settings = json.loads((user_home / ".vscode-server/data/Machine/settings.json").read_text())
                        self.assertEqual(terminal_settings["http.proxy"], f"http://127.0.0.1:{config['mixed-port']}")
                        for script in ("run.sh", "stop.sh", "status.sh", "proxy.sh"):
                            subprocess.run(["bash", "-n", str(destination / script)], check=True)
                        # Re-running the same entry preserves config, process and unrelated cron jobs.
                        previous = (destination / "config.yaml").read_bytes()
                        retry = subprocess.run(["bash", str(PROJECT / "install.sh")], input=str(destination) + "\n\n\ny\nn\ny\n",
                                               text=True, capture_output=True, env=interactive_env, timeout=20)
                        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                        self.assertEqual((destination / "config.yaml").read_bytes(), previous)
                        self.assertEqual(int(pid_path.read_text()), pid)
                        self.assertEqual(cron_file.read_text().count("# " + r.unit_name(destination)), 1)
                        # Upgrade an existing ordinary configuration through the same entry.
                        ordinary = (destination / r.SOURCE).read_bytes()
                        r.atomic_write(destination / "config.yaml", ordinary)
                        (destination / r.SOURCE).unlink()
                        (destination / r.SETTINGS).unlink()
                        retry_answers = [str(destination), "y", compact, private_settings["expected_exit_ip"], "y", "n", "y"]
                        retry = subprocess.run(["bash", str(PROJECT / "install.sh")], input="\n".join(retry_answers) + "\n",
                                               text=True, capture_output=True, env=interactive_env, timeout=20)
                        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
                        upgraded = r.read_yaml(destination / "config.yaml")
                        self.assertEqual(upgraded["mixed-port"], config["mixed-port"])
                        self.assertEqual(upgraded["secret"], config["secret"])
                        self.assertNotIn("proxy-providers", upgraded)
                        self.assertEqual((destination / "config.before-residential.yaml").read_bytes(), ordinary)
                        self.assertEqual(int(pid_path.read_text()), pid)
                        previous = (destination / "config.yaml").read_bytes()
                        # An invalid change to an existing installation must preserve its working config.
                        credentials.write_text(json.dumps({**private_settings, "port": "invalid"}))
                        retry = subprocess.run(["bash", str(PROJECT / "install.sh")], input=str(destination) + "\n",
                                               text=True, capture_output=True, env=env, timeout=10)
                        self.assertNotEqual(retry.returncode, 0)
                        self.assertEqual((destination / "config.yaml").read_bytes(), previous)
                    else:
                        self.assertFalse((destination / "config.yaml").exists())
                        self.assertTrue((destination / "config.setup-incomplete.yaml").is_file())
                        self.assertFalse((destination / "run.sh").exists())


if __name__ == "__main__":
    unittest.main()
