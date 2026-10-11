#!/usr/bin/env python3
"""Credential-injecting reverse proxy for the model API (Python stdlib only).

The agent sends plain HTTP to this proxy with a placeholder key. The proxy forwards only
allowlisted paths and models to ONE fixed HTTPS upstream and adds the real API key.
The real key never enters the agent container.

Env:
  OLLAMA_API_KEY           required, the real key (removed from os.environ after start)
  API_UPSTREAM             upstream base URL, https only (default https://ollama.com)
  API_PROXY_PORT           listen port (default 8080)
  API_PROXY_ALLOWED_PATHS  space list of path prefixes (default "/v1/")
  API_PROXY_MODELS         optional comma/space list; requests naming another model get 403
  API_PROXY_MAX_REQUESTS   optional per-session request cap, 0 = unlimited (default 0)
  API_PROXY_MAX_BODY       max request body bytes (default 33554432)
  API_PROXY_TIMEOUT        upstream timeout seconds (default 600)
  API_PROXY_FORCE_STREAM_USAGE  1 = add stream_options.include_usage=true to streaming chat requests
                           that lack it, so token counts are reported for streams (default 0)
  VIEWER_LOG_TARGET        optional host:port of the egress monitor (UDP, same line format as squid)
"""
import http.client
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = urllib.parse.urlsplit(os.environ.get("API_UPSTREAM", "https://ollama.com"))
API_KEY = os.environ.pop("OLLAMA_API_KEY", "")
PORT = int(os.environ.get("API_PROXY_PORT", "8080"))
ALLOWED_PREFIXES = tuple(p for p in os.environ.get("API_PROXY_ALLOWED_PATHS", "/v1/").split() if p)
ALLOWED_MODELS = {m for m in os.environ.get("API_PROXY_MODELS", "").replace(",", " ").split() if m}
MAX_REQUESTS = int(os.environ.get("API_PROXY_MAX_REQUESTS", "0"))
MAX_BODY = int(os.environ.get("API_PROXY_MAX_BODY", str(32 * 1024 * 1024)))
TIMEOUT = int(os.environ.get("API_PROXY_TIMEOUT", "600"))
LOG_TARGET = os.environ.get("VIEWER_LOG_TARGET", "")
FORCE_STREAM_USAGE = os.environ.get("API_PROXY_FORCE_STREAM_USAGE", "0") == "1"
USAGE_JSON_LIMIT = 8 * 1024 * 1024   # non-streaming bodies larger than this are not parsed for usage
USAGE_LINE_LIMIT = 1024 * 1024       # SSE lines longer than this are skipped

# Never forwarded upstream: hop-by-hop headers and anything credential-like the agent sends.
STRIP_REQUEST = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
                 "trailers", "transfer-encoding", "upgrade", "host", "content-length",
                 "authorization", "x-api-key", "api-key", "cookie",
                 "accept-encoding"}  # identity upstream responses keep token usage parseable
STRIP_RESPONSE = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
                  "trailers", "transfer-encoding", "upgrade", "set-cookie"}

_count = 0
_count_lock = threading.Lock()
_udp = None
_ssl_ctx = ssl.create_default_context()



def safe_model(model):
    """Model name for logs: agent-controlled input, so restrict charset and length."""
    if not isinstance(model, str) or not model:
        return "-"
    return re.sub(r"[^A-Za-z0-9._:/@+-]", "_", model)[:100]


class UsageTracker:
    """Extracts token usage from JSON or SSE response bodies while they stream through.

    Understands OpenAI chat completions (usage.prompt_tokens/completion_tokens), the Responses API
    (response.usage.input_tokens/output_tokens), Anthropic-style messages (input_tokens in
    message_start, cumulative output_tokens in message_delta) and Ollama native counters.
    """

    def __init__(self, content_type):
        ct = (content_type or "").lower()
        self.sse = "text/event-stream" in ct or "ndjson" in ct   # line-oriented streams
        self.json = not self.sse and "json" in ct
        self.buf = b""
        self.tokens_in = None
        self.tokens_out = None

    def _take(self, obj):
        if not isinstance(obj, dict):
            return
        for u in (obj.get("usage"), (obj.get("response") or {}).get("usage") if isinstance(obj.get("response"), dict) else None,
                  (obj.get("message") or {}).get("usage") if isinstance(obj.get("message"), dict) else None):
            if isinstance(u, dict):
                i = u.get("prompt_tokens", u.get("input_tokens"))
                o = u.get("completion_tokens", u.get("output_tokens"))
                if isinstance(i, int) and i > 0:
                    self.tokens_in = i
                if isinstance(o, int) and o > 0:
                    self.tokens_out = o
        if isinstance(obj.get("prompt_eval_count"), int):
            self.tokens_in = obj["prompt_eval_count"]
        if isinstance(obj.get("eval_count"), int):
            self.tokens_out = obj["eval_count"]

    def feed(self, chunk):
        if self.sse:
            self.buf += chunk
            *lines, self.buf = self.buf.split(b"\n")
            if len(self.buf) > USAGE_LINE_LIMIT:
                self.buf = b""
            for line in lines:
                line = line.strip()
                if line.startswith(b"data:") and b"usage" in line or b"eval_count" in line:
                    try:
                        self._take(json.loads(line[5:].strip() if line.startswith(b"data:") else line))
                    except ValueError:
                        pass
        elif self.json and len(self.buf) <= USAGE_JSON_LIMIT:
            self.buf += chunk

    def finish(self):
        if self.json and self.buf and len(self.buf) <= USAGE_JSON_LIMIT:
            try:
                self._take(json.loads(self.buf))
            except ValueError:
                pass
        self.buf = b""


def log(start, client, code, status, up, down, method, server, path, model=None, usage=None):
    """One line per request: squid 'viewer' format plus model, tokens_in, tokens_out; never the key."""
    url = f"{UPSTREAM.scheme}://{UPSTREAM.hostname}{path.split('?', 1)[0]}"
    tin = usage.tokens_in if usage and usage.tokens_in is not None else "-"
    tout = usage.tokens_out if usage and usage.tokens_out is not None else "-"
    line = (f"{start:.3f} {int((time.time() - start) * 1000)} {client} {code} {status} "
            f"{up} {down} {method} {server or '-'} {url} {safe_model(model)} {tin} {tout}")
    print(line, flush=True)
    if LOG_TARGET and _udp is not None:
        host, _, port = LOG_TARGET.rpartition(":")
        try:
            _udp.sendto((line + "\n").encode(), (host, int(port)))
        except OSError:
            pass  # monitoring must never break the data path


def path_allowed(path):
    p = urllib.parse.unquote(path.split("?", 1)[0])
    if "/../" in p or p.endswith("/..") or "\\" in p:
        return False
    return p.startswith(ALLOWED_PREFIXES)


def model_denial(model, has_body):
    """Return a denial reason when a request body bypasses the configured model allowlist."""
    if not ALLOWED_MODELS or not has_body:
        return None
    if not isinstance(model, str) or not model:
        return "request must name an allowed model"
    if model not in ALLOWED_MODELS:
        return f"model '{model}' not allowed"
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "api-proxy"
    sys_version = ""

    def log_message(self, *args):
        pass

    def _reply(self, status, text):
        body = (json.dumps({"error": {"message": text, "type": "api_proxy"}}) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _handle(self):
        global _count
        start = time.time()
        client = self.client_address[0]
        method = self.command
        path = self.path
        if not path.startswith("/"):  # absolute-form, e.g. via a forward proxy
            u = urllib.parse.urlsplit(path)
            path = u.path + (("?" + u.query) if u.query else "")

        if path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "3")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"ok\n")
            self.close_connection = True
            return

        model = None

        def deny(status, reason):
            self._reply(status, reason)
            log(start, client, "API_DENIED", status, 0, 0, method, None, path, model)

        if not path_allowed(path):
            return deny(403, "path not allowed")
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            return deny(411, "chunked request bodies are not supported")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return deny(400, "bad content-length")
        if length > MAX_BODY:
            return deny(413, "request body too large")
        body = self.rfile.read(length) if length else b""

        req_json = None
        if body:
            try:
                req_json = json.loads(body)
                model = req_json.get("model") if isinstance(req_json, dict) else None
            except ValueError:
                req_json = None
        # Fail closed when a request body could select a model. Invalid JSON, a non-object
        # payload, or a missing/non-string model must not bypass the configured allowlist.
        # Bodyless requests such as GET /v1/models remain available for discovery.
        model_error = model_denial(model, bool(body))
        if model_error:
            return deny(403, model_error)

        with _count_lock:
            _count += 1
            n = _count
        if MAX_REQUESTS and n > MAX_REQUESTS:
            return deny(429, f"session request cap ({MAX_REQUESTS}) reached")

        # Streaming chat completions only report usage when the client asks for it.
        if (FORCE_STREAM_USAGE and isinstance(req_json, dict) and req_json.get("stream") is True
                and path.split("?", 1)[0].endswith("/chat/completions")):
            so = req_json.get("stream_options")
            if not isinstance(so, dict) or "include_usage" not in so:
                req_json["stream_options"] = {**(so if isinstance(so, dict) else {}), "include_usage": True}
                body = json.dumps(req_json).encode()

        headers = {k: v for k, v in self.headers.items() if k.lower() not in STRIP_REQUEST}
        headers["Host"] = UPSTREAM.hostname
        headers["Authorization"] = f"Bearer {API_KEY}"
        if body or method in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))

        upstream_path = UPSTREAM.path.rstrip("/") + path
        conn = http.client.HTTPSConnection(UPSTREAM.hostname, UPSTREAM.port or 443,
                                           timeout=TIMEOUT, context=_ssl_ctx)
        down = 0
        server = None
        usage = None
        try:
            conn.request(method, upstream_path, body=body or None, headers=headers)
            try:
                server = conn.sock.getpeername()[0]  # before getresponse(), which may drop conn.sock
            except (OSError, AttributeError):
                server = None
            resp = conn.getresponse()
            usage = UsageTracker(resp.getheader("Content-Type"))
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in STRIP_RESPONSE:
                    self.send_header(k, v)
            self.send_header("Connection", "close")  # close-delimited body = streaming without re-chunking
            self.end_headers()
            if method != "HEAD":
                while True:
                    chunk = resp.read1(65536)  # read1 returns as soon as data arrives (SSE streaming)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    down += len(chunk)
                    usage.feed(chunk)
            usage.finish()
            self.close_connection = True
            log(start, client, "API_INJECT", resp.status, len(body), down, method, server, path, model, usage)
        except (BrokenPipeError, ConnectionResetError):
            log(start, client, "API_CLIENT_ABORT", 499, len(body), down, method, server, path, model, usage)
        except Exception as e:  # noqa: BLE001 - upstream failure, report without details of the request
            try:
                self._reply(502, f"upstream error: {type(e).__name__}")
            except OSError:
                pass
            log(start, client, "API_UPSTREAM_ERROR", 502, len(body), down, method, server, path, model)
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _handle


def main():
    global _udp
    if UPSTREAM.scheme != "https" or not UPSTREAM.hostname:
        sys.exit("api-proxy: API_UPSTREAM must be an https URL")
    if not API_KEY:
        sys.exit("api-proxy: OLLAMA_API_KEY not set")
    if LOG_TARGET:
        _udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"api-proxy: :{PORT} -> {UPSTREAM.scheme}://{UPSTREAM.hostname} "
          f"paths={' '.join(ALLOWED_PREFIXES)} models={','.join(sorted(ALLOWED_MODELS)) or 'any'} "
          f"cap={MAX_REQUESTS or 'none'}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
