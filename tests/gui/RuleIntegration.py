#!/usr/bin/env python3
"""Run generated rules in a real isolated mihomo, using IPv4/IPv6 loopback servers."""
import http.client
import http.server
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b"RNDIS RULE TEST"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class IPv6Server(http.server.HTTPServer):
    address_family = socket.AF_INET6


class Controller(http.client.HTTPConnection):
    def __init__(self, endpoint):
        super().__init__("localhost", timeout=2)
        self.endpoint = endpoint

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.endpoint)


def control(endpoint, method, path, body=None):
    client = Controller(endpoint)
    try:
        client.request(method, path, body=json.dumps(body) if body is not None else None,
                       headers={"Content-Type": "application/json"})
        response = client.getresponse()
        data = response.read()
        assert 200 <= response.status < 300, (response.status, data)
        return json.loads(data) if data else {}
    finally:
        client.close()


probe = str(Path(sys.argv[1]).resolve())
mihomo = str(Path(sys.argv[2]).resolve())
servers = [http.server.HTTPServer(("127.0.0.1", 0), Handler),
           IPv6Server(("::1", 0), Handler)]
# Reserve a third, deliberately unmatched port to catch an accidental OR condition.
while True:
    outside = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    if outside.server_port not in [servers[0].server_port, servers[0].server_port + 1]:
        servers.append(outside)
        break
    outside.server_close()
threads = []
for server in servers:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    threads.append(thread)

process = None
try:
    with tempfile.TemporaryDirectory(prefix="rndis-rules-", dir="/tmp") as folder:
        root = Path(folder)
        endpoint = str(root / "control.sock")
        config_path = root / "config.json"
        port4, port6 = servers[0].server_port, servers[1].server_port
        range_end = min(port4 + 1, 65535)
        targets = [f"rndis.example.test:{port4}", f"127.0.0.99/24:{port4}-{range_end}",
                   f"[::abcd/112]:{port6}"]
        subprocess.run([probe, "--export-config", str(config_path), *targets], check=True)
        config = json.loads(config_path.read_text())
        with socket.socket() as temporary:
            temporary.bind(("127.0.0.1", 0))
            proxy_port = temporary.getsockname()[1]
        config.update({"mixed-port": proxy_port, "bind-address": "127.0.0.1", "allow-lan": False,
                       "external-controller-unix": endpoint, "secret": "",
                       "hosts": {"rndis.example.test": "127.0.0.1", "cidr.example.test": "127.0.0.1", "cidr6.example.test": "::1"}, "log-level": "warning"})
        config["dns"]["use-hosts"] = True
        # Keep test traffic on loopback while exercising the generated dual-stack outbound.
        config["proxies"][0]["interface-name"] = "lo0"
        config["rules"][-1] = "MATCH,REJECT"
        config_path.write_text(json.dumps(config))
        with (root / "mihomo.log").open("w+") as log:
            process = subprocess.Popen([mihomo, "-d", folder, "-f", str(config_path)],
                                       stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    log.seek(0)
                    raise AssertionError(log.read())
                try:
                    control(endpoint, "GET", "/version")
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(.05)
            control(endpoint, "PUT", "/proxies/RNDIS%20Tether", {"name": "RNDIS Tether USB"})

            def fetch(url, success):
                result = subprocess.run(["/usr/bin/curl", "--proxy", f"http://127.0.0.1:{proxy_port}",
                                         "--noproxy", "", "--max-time", "4", "-fsS", url],
                                        capture_output=True, text=True, timeout=6)
                assert (result.returncode == 0) == success, (url, result.stdout, result.stderr)
                if success:
                    assert result.stdout == "RNDIS RULE TEST", result.stdout

            fetch(f"http://rndis.example.test:{port4}/", True)
            fetch(f"http://127.0.0.1:{port4}/", True)
            fetch(f"http://cidr.example.test:{port4}/", True)
            fetch(f"http://cidr6.example.test:{port6}/", True)
            fetch(f"http://[::1]:{port6}/", True)
            fetch(f"http://127.0.0.1:{servers[2].server_port}/", False)
            fetch(f"http://rndis.example.test:{servers[2].server_port}/", False)
            print("PASS real mihomo: domain+port, IPv4 CIDR+range, IPv6 CIDR+port, and unmatched-port rejection")
finally:
    if process is not None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for server in servers:
        server.shutdown()
        server.server_close()
    for thread in threads:
        thread.join()
