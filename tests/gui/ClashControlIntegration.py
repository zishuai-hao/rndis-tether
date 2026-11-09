#!/usr/bin/env python3
"""Exercise the actual native Unix HTTP client and durable recovery journal offline."""
import http.server
import json
import os
from pathlib import Path
import socketserver
import subprocess
import sys
import tempfile
import threading


class Controller(socketserver.UnixStreamServer):
    now = "DIRECT"
    reject_put = False
    malformed_group = False


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        assert self.path == "/proxies/RNDIS%20Tether"
        group = {"type": "Selector", "all": ["DIRECT", "RNDIS Tether USB"], "now": self.server.now}
        if self.server.malformed_group:
            group["type"] = "URLTest"
        body = json.dumps(group).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        assert self.path == "/proxies/RNDIS%20Tether"
        value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.server.reject_put:
            self.send_response(503)
        else:
            self.server.now = value["name"]
            self.send_response(204)
        self.end_headers()


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="rndis-clash-", dir="/tmp") as folder:
    endpoint = folder + "/control.sock"
    journal = Path(folder) / "settings" / "journal.json"
    server = Controller(endpoint, Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def run(operation, owner=12345, success=True):
        result = subprocess.run([binary, "--control", endpoint, str(journal), operation, str(owner)], capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == success, result.stdout + result.stderr

    try:
        run("enable")
        assert server.now == "RNDIS Tether USB"
        assert json.loads(journal.read_text()) == {"owner": 12345, "previous": "DIRECT"}
        assert os.stat(journal).st_mode & 0o777 == 0o600
        run("enable")
        run("enable", owner=98765, success=False)
        run("restore", owner=98765)
        assert journal.exists() and server.now == "RNDIS Tether USB"
        # A disconnected controller must leave recovery intent on disk.
        server.reject_put = True
        run("restore", success=False)
        assert journal.exists()
        server.reject_put = False
        run("restore")
        assert server.now == "DIRECT" and not journal.exists()
        run("enable")
        server.now = "DIRECT"  # Respect a manual selection made after enable.
        run("restore")
        assert server.now == "DIRECT" and not journal.exists()
        server.reject_put = True
        run("enable", success=False)
        assert server.now == "DIRECT" and not journal.exists()
        server.reject_put = False
        server.malformed_group = True
        run("enable", success=False)
        assert not journal.exists()
        print("PASS real Unix HTTP requests, journal permissions, retries, owner isolation and recovery")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
