#!/usr/bin/env python3
"""Egress monitor for the squid sidecar.

Receives squid access-log lines over UDP (logformat "viewer"), keeps a ring buffer,
polls the cache manager for open tunnels, and serves a live Wireshark-style web view.
Python standard library only.
"""
import base64
import json
import os
import queue
import re
import socket
import threading
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UDP_PORT = int(os.environ.get("VIEWER_UDP_PORT", "5140"))
HTTP_PORT = int(os.environ.get("VIEWER_HTTP_PORT", "8080"))
MAX_ROWS = int(os.environ.get("VIEWER_MAX_ROWS", "10000"))
BACKLOG = int(os.environ.get("VIEWER_BACKLOG", "2000"))
MGR_URL = os.environ.get("PROXY_MGR_URL", "")
MGR_PASSWORD = os.environ.get("MGR_PASSWORD", "")
SESSION = os.environ.get("SESSION_NAME", "")
TOR_MODE = os.environ.get("TOR_MODE", "0") == "1"
TOR_EXIT_IP = os.environ.get("TOR_EXIT_IP", "")
ALLOWED_HOSTS = {h.strip().lower() for h in os.environ.get("VIEWER_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",") if h.strip()}

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"), "rb") as f:
    INDEX = f.read()

_rows = deque(maxlen=MAX_ROWS)
_subs = set()
_lock = threading.Lock()
_seq = 0

URL_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://\[?([^/\]:]+)\]?(?::(\d+))?")


def parse(line):
    # squid lines: 10 fields. API proxy lines: + model (11), + tokens_in tokens_out (13).
    parts = line.split(" ", 12)
    if len(parts) not in (10, 11, 13):
        return None
    ts, dur, client, code, status, up, down, method, server, url = parts[:10]
    extra = [p.strip() for p in parts[10:]]
    model = extra[0] if extra and extra[0] not in ("", "-") else ""

    def tok(i):
        return int(extra[i]) if len(extra) > i and extra[i].isdigit() else None
    tokens_in, tokens_out = tok(1), tok(2)
    if "/squid-internal-mgr/" in url:
        return None  # the monitor's own polling
    try:
        ts, dur, up, down = float(ts), int(dur), int(up), int(down)
    except ValueError:
        return None
    host, port, path = url, "", ""
    if method == "CONNECT":
        h, _, p = url.rpartition(":")
        if h:
            host, port = h.strip("[]"), p
    else:
        m = URL_RE.match(url)
        if m:
            host = m.group(1)
            port = m.group(2) or ("443" if url.lower().startswith("https") else "80")
            path = url[m.end():] or "/"
    if "DENIED" in code:
        verdict = "denied"
    elif code == "TCP_TUNNEL" or status.startswith(("2", "3")):
        verdict = "allowed"
    else:
        verdict = "error"
    return {"ts": ts, "dur": dur, "client": client, "code": code, "status": status,
            "up": up, "down": down, "method": method, "server": server, "url": url,
            "host": host, "port": port, "path": path, "verdict": verdict, "model": model,
            "tokens_in": tokens_in, "tokens_out": tokens_out}


def udp_loop():
    global _seq
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", UDP_PORT))
    while True:
        data, _ = sock.recvfrom(65535)
        for line in data.decode("utf-8", "replace").splitlines():
            row = parse(line.strip())
            if not row:
                continue
            with _lock:
                _seq += 1
                row["no"] = _seq
                _rows.append(row)
                subs = list(_subs)
            msg = json.dumps(row)
            for q in subs:
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    pass  # slow browser; it drops rows rather than blocking ingestion


def _field(pattern, text):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else ""


def active_tunnels():
    """Best effort: parses the cache manager 'active_requests' text report."""
    if not MGR_URL:
        return {"available": False, "reason": "PROXY_MGR_URL not set"}
    req = urllib.request.Request(MGR_URL)
    if MGR_PASSWORD:
        token = base64.b64encode(f"monitor:{MGR_PASSWORD}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=3) as r:
            text = r.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return {"available": False, "reason": str(e)[:200]}
    conns = []
    for block in re.split(r"^Connection: ", text, flags=re.M)[1:]:
        uri = _field(r"^uri (\S+)", block)
        if not uri or "squid-internal-mgr" in uri:
            continue
        age = _field(r"^start \S+ \(([\d.]+) seconds ago\)", block)
        conns.append({
            "uri": uri,
            "client": _field(r"^\s*remote: (\S+)", block),
            "type": _field(r"^logType (\S+)", block),
            "age": float(age) if age else None,
            "read": int(_field(r"FD \d+, read (\d+)", block) or 0),
            "wrote": int(_field(r"wrote (\d+)", block) or 0),
        })
    return {"available": True, "connections": conns}


class Handler(BaseHTTPRequestHandler):
    server_version = "egress-monitor"
    sys_version = ""

    def log_message(self, *args):
        pass

    def _headers(self, code, ctype, length=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-ancestors 'none'")
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.end_headers()

    def _send(self, code, ctype, body):
        self._headers(code, ctype, len(body))
        self.wfile.write(body)

    def _json(self, obj):
        self._send(200, "application/json", json.dumps(obj).encode())

    def do_GET(self):
        # DNS-rebinding guard: only answer for expected Host names.
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host not in ALLOWED_HOSTS:
            return self._send(403, "text/plain", b"forbidden host")
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._send(200, "text/html; charset=utf-8", INDEX)
        if path == "/healthz":
            return self._send(200, "text/plain", b"ok")
        if path == "/api/info":
            return self._json({"session": SESSION, "maxRows": MAX_ROWS,
                               "tor": TOR_MODE, "torExitIp": TOR_EXIT_IP})
        if path == "/api/active":
            return self._json(active_tunnels())
        if path == "/api/rows":
            with _lock:
                return self._json(list(_rows))
        if path == "/events":
            return self._events()
        self._send(404, "text/plain", b"not found")

    def _events(self):
        q = queue.Queue(maxsize=5000)
        with _lock:
            backlog = list(_rows)[-BACKLOG:]
            _subs.add(q)
        try:
            self._headers(200, "text/event-stream")
            for row in backlog:
                self.wfile.write(f"data: {json.dumps(row)}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    msg = q.get(timeout=15)
                    self.wfile.write(f"data: {msg}\n\n".encode())
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with _lock:
                _subs.discard(q)


def main():
    threading.Thread(target=udp_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    server.daemon_threads = True
    print(f"monitor: http :{HTTP_PORT}, udp :{UDP_PORT}, session '{SESSION}'", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
