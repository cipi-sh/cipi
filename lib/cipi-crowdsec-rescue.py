#!/usr/bin/env python3
"""Cipi CrowdSec rescue — TLS listener, not a login.

Accepts one GET with the current one-shot token. On match, allowlists the
TCP peer IP (never X-Forwarded-For / X-Real-IP) and rotates the token.
Does not open a shell, does not add SSH keys, does not change sshd.
"""
from __future__ import annotations

import fcntl
import hmac
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from collections import defaultdict, deque
from typing import Deque, Dict

CONFIG = os.environ.get("CIPI_CONFIG", "/etc/cipi")
PORT_FILE = os.path.join(CONFIG, "crowdsec-rescue.port")
TOKEN_FILE = os.path.join(CONFIG, "crowdsec-rescue.token")
LOCK_FILE = os.path.join(CONFIG, "crowdsec-rescue.lock")
CERT_FILE = os.path.join(CONFIG, "crowdsec-rescue.crt")
KEY_FILE = os.path.join(CONFIG, "crowdsec-rescue.key")
CIPI = "/usr/local/bin/cipi"
TOKEN_RE = re.compile(r"^[a-f0-9]{64}$")
# `cipi crowdsec redeem` reloads CrowdSec and sends mail; 30s was tight enough
# that a slow SMTP server turned a successful rescue into a 500.
REDEEM_TIMEOUT = 90
# Sliding window against token-guessing from one peer.
WINDOW = 60.0
MAX_FAILS = 8
MAX_TRACKED_PEERS = 4096
_fails: Dict[str, Deque[float]] = defaultdict(deque)
_fails_lock = threading.Lock()
# A stalled peer must never reach the accept loop, so the TLS handshake runs in
# the worker thread with a deadline of its own.
HANDSHAKE_TIMEOUT = 5.0
# Bounded so a connection flood cannot walk into the unit's TasksMax and take
# the listener down with it.
MAX_CONCURRENT = 32
_slots = threading.BoundedSemaphore(MAX_CONCURRENT)


def _read(path: str) -> str:
    with open(path, "r", encoding="ascii") as fh:
        return fh.read().strip()


def _peer_ip(handler: BaseHTTPRequestHandler) -> str:
    # Socket peer only. Headers that claim a client IP are ignored on purpose.
    host = handler.client_address[0]
    if host.startswith("::ffff:"):
        host = host[7:]
    return host


def _rate_ok(ip: str) -> bool:
    now = time.monotonic()
    with _fails_lock:
        q = _fails[ip]
        while q and now - q[0] > WINDOW:
            q.popleft()
        return len(q) < MAX_FAILS


def _rate_hit(ip: str) -> None:
    with _fails_lock:
        if len(_fails) >= MAX_TRACKED_PEERS and ip not in _fails:
            # One deque per source address is unbounded memory for a port anyone
            # can reach. Drop windows that have already expired, then give up on
            # tracking rather than grow.
            now = time.monotonic()
            for stale in [k for k, q in _fails.items() if not q or now - q[-1] > WINDOW]:
                del _fails[stale]
            if len(_fails) >= MAX_TRACKED_PEERS:
                return
        _fails[ip].append(time.monotonic())


def _scrape_token(out: str) -> str:
    for line in (out or "").splitlines():
        if line.startswith("RESCUE_OK "):
            return line[len("RESCUE_OK ") :].strip()
    return ""


def _redeem(ip: str) -> str:
    env = os.environ.copy()
    env["CIPI_RESCUE_REDEEM"] = "1"
    try:
        proc = subprocess.run(
            [CIPI, "crowdsec", "redeem", ip],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=REDEEM_TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        # redeem rotates the token before it does anything slow, so the new one
        # is already in the partial output. Dropping it here would leave the
        # operator with a burnt token and no replacement — the mail that also
        # carries it is exactly what may be hanging.
        sys.stderr.write("redeem timed out after %ss\n" % REDEEM_TIMEOUT)
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("ascii", "replace")
        return _scrape_token(out)
    if proc.returncode != 0:
        sys.stderr.write("redeem failed rc=%s err=%s\n" % (proc.returncode, (proc.stderr or "")[:200]))
        return ""
    return _scrape_token(proc.stdout)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 10
    # Do not advertise "BaseHTTP/x Python/y" to whoever port-scans this.
    server_version = "cipi"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        # Do not log the request line — it contains the token.
        sys.stderr.write("rescue peer=%s\n" % (_peer_ip(self),))

    def _send(self, code: int, body: str) -> None:
        data = body.encode("ascii", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=us-ascii")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:
        self._send(405, "GET only\n")

    def do_PUT(self) -> None:
        self._send(405, "GET only\n")

    def _reject(self, ip: str) -> None:
        # The throttle applies to wrong tokens only. A correct 256-bit token is
        # always honoured: this is the path someone locked out of SSH uses, and
        # refusing it because they fat-fingered the URL twice defeats the point.
        _rate_hit(ip)
        self._send(429 if not _rate_ok(ip) else 403, "forbidden\n")

    def do_GET(self) -> None:
        ip = _peer_ip(self)
        if ip in ("127.0.0.1", "::1", ""):
            self._send(403, "forbidden\n")
            return
        path = self.path.split("?", 1)[0]
        token = path.lstrip("/")
        if not TOKEN_RE.match(token):
            self._reject(ip)
            return
        try:
            os.makedirs(CONFIG, exist_ok=True)
            with open(LOCK_FILE, "a+", encoding="ascii") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                expected = _read(TOKEN_FILE)
                if len(expected) != 64 or not hmac.compare_digest(expected, token):
                    self._reject(ip)
                    return
                new = _redeem(ip)
                if not new:
                    self._send(500, "allowlist failed\n")
                    return
        except FileNotFoundError:
            self._send(503, "rescue unconfigured\n")
            return
        except Exception as exc:
            sys.stderr.write("rescue error: %s\n" % exc)
            self._send(500, "error\n")
            return
        self._send(200, "allowlisted %s\nnext %s\n" % (ip, new))


class _TLSServer(ThreadingMixIn, HTTPServer):
    """HTTP over TLS with the handshake in the worker thread.

    Wrapping the *listening* socket (the obvious way) makes accept() perform the
    handshake, so one peer that opens a connection and never sends a ClientHello
    stops the accept loop for as long as it holds the socket — the break-glass
    path is then closed by anyone who can reach the port, which is everyone.
    """

    daemon_threads = True
    allow_reuse_address = True
    ssl_context: ssl.SSLContext

    def get_request(self):
        sock, addr = super().get_request()
        sock.settimeout(HANDSHAKE_TIMEOUT)
        return sock, addr

    def process_request(self, request, client_address) -> None:
        if not _slots.acquire(blocking=False):
            sys.stderr.write("rescue: at capacity, dropped %s\n" % (client_address[0],))
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            _slots.release()
            raise

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            _slots.release()

    def finish_request(self, request, client_address) -> None:
        try:
            tls = self.ssl_context.wrap_socket(request, server_side=True)
        except (OSError, ValueError):
            # Port scan, plain HTTP, or a handshake that ran out of time.
            return
        try:
            self.RequestHandlerClass(tls, client_address, self)
        finally:
            try:
                tls.close()
            except OSError:
                pass

    def handle_error(self, request, client_address) -> None:
        sys.stderr.write("rescue: connection error from %s\n" % (client_address[0],))


class _TLSServer6(_TLSServer):
    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def main() -> int:
    for path in (PORT_FILE, TOKEN_FILE, CERT_FILE, KEY_FILE):
        if not os.path.isfile(path):
            sys.stderr.write("missing %s\n" % path)
            return 1
    port = int(_read(PORT_FILE))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    _TLSServer.ssl_context = ctx
    httpd: HTTPServer
    try:
        httpd = _TLSServer6(("::", port), Handler)
    except OSError:
        httpd = _TLSServer(("0.0.0.0", port), Handler)
    sys.stderr.write("cipi-crowdsec-rescue listening on %s\n" % port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
