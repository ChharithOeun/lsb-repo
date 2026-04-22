"""Transport-layer tests: stubbed AIBridgeClient against a loopback socket,
and AdminAPIClient against a tiny http.server.
"""
from __future__ import annotations

import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import List

import pytest

from chharbot.bridges import AdminAPIClient, AIBridgeClient, BridgeError


# ---------- ai_bridge over loopback -----------------------------------------

def _serve_one_ai_client(port_holder: list, script: list[str], token: str = ""):
    """Serve exactly one client, replying with canned lines."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port_holder.append(srv.getsockname()[1])
    conn, _ = srv.accept()
    try:
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk: return
            buf += chunk
        first = json.loads(buf.split(b"\n", 1)[0].decode())
        # If a token is expected, the first message must be the handshake.
        if token:
            assert "auth" in first and first["auth"] == token
            conn.sendall((json.dumps({"jsonrpc": "2.0", "id": first.get("id"),
                                      "result": {"ok": True}}) + "\n").encode())
            buf = buf.split(b"\n", 1)[1]
            while b"\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk: return
                buf += chunk
            second = json.loads(buf.split(b"\n", 1)[0].decode())
            target = second
        else:
            target = first
        # Reply with the first scripted line, matching request id.
        resp = json.loads(script.pop(0))
        resp["id"] = target.get("id")
        conn.sendall((json.dumps(resp) + "\n").encode())
    finally:
        conn.close()
        srv.close()


def test_ai_bridge_round_trip_no_token():
    port_holder: list = []
    script = [json.dumps({"jsonrpc": "2.0", "result": {"pong": True}})]
    t = threading.Thread(target=_serve_one_ai_client, args=(port_holder, script, ""))
    t.start()
    # Wait for server to bind before connecting.
    while not port_holder: time.sleep(0.01)
    client = AIBridgeClient(host="127.0.0.1", port=port_holder[0], timeout=2.0)
    try:
        assert client.ping() == {"pong": True}
    finally:
        client.close()
    t.join(timeout=2)


def test_ai_bridge_handshake_with_token():
    port_holder: list = []
    script = [json.dumps({"jsonrpc": "2.0", "result": {"pong": True}})]
    tok = "s3cret"
    t = threading.Thread(target=_serve_one_ai_client, args=(port_holder, script, tok))
    t.start()
    while not port_holder: time.sleep(0.01)
    client = AIBridgeClient(host="127.0.0.1", port=port_holder[0], token=tok, timeout=2.0)
    try:
        assert client.ping() == {"pong": True}
    finally:
        client.close()
    t.join(timeout=2)


def test_ai_bridge_error_response_raises():
    port_holder: list = []
    script = [json.dumps({"jsonrpc": "2.0", "error": {"code": -32601, "message": "nope"}})]
    t = threading.Thread(target=_serve_one_ai_client, args=(port_holder, script, ""))
    t.start()
    while not port_holder: time.sleep(0.01)
    client = AIBridgeClient(host="127.0.0.1", port=port_holder[0], timeout=2.0)
    try:
        with pytest.raises(BridgeError):
            client.ping()
    finally:
        client.close()
    t.join(timeout=2)


# ---------- admin API over loopback HTTP ------------------------------------

class _AdminStub(BaseHTTPRequestHandler):
    # Quiet the default stderr logging during tests.
    def log_message(self, *a, **k): return

    seen_tokens: List[str] = []

    def _send_json(self, code, body):
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        _AdminStub.seen_tokens.append(self.headers.get("X-Admin-Token", ""))
        if self.path == "/health":
            return self._send_json(200, {"ok": True, "ts": 1})
        if self.path == "/server_stats":
            return self._send_json(200, {"chars": 2, "accounts": 3})
        if self.path.startswith("/players/"):
            pid = int(self.path.rsplit("/", 1)[-1])
            return self._send_json(200, {"id": pid})
        return self._send_json(404, {"detail": "nope"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        _AdminStub.seen_tokens.append(self.headers.get("X-Admin-Token", ""))
        if self.path == "/announce":
            if not body.get("text"):
                return self._send_json(400, {"detail": "text required"})
            return self._send_json(200, {"ok": True, "echo": body["text"]})
        return self._send_json(404, {"detail": "nope"})


@pytest.fixture
def http_stub():
    _AdminStub.seen_tokens = []
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _AdminStub)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        yield f"http://127.0.0.1:{port}", _AdminStub.seen_tokens
    finally:
        srv.shutdown()
        srv.server_close()


def test_admin_client_reads(http_stub):
    base, seen = http_stub
    c = AdminAPIClient(base_url=base, token="tok")
    assert c.health()["ok"] is True
    assert c.server_stats()["chars"] == 2
    assert c.player(42)["id"] == 42
    assert all(t == "tok" for t in seen)


def test_admin_client_write_needs_flag(http_stub):
    base, _ = http_stub
    c = AdminAPIClient(base_url=base, token="tok", allow_writes=False)
    with pytest.raises(BridgeError):
        c.announce("hi")


def test_admin_client_write_happy_path(http_stub):
    base, _ = http_stub
    c = AdminAPIClient(base_url=base, token="tok", allow_writes=True)
    r = c.announce("hello world")
    assert r == {"ok": True, "echo": "hello world"}


def test_admin_client_surfaces_http_error(http_stub):
    base, _ = http_stub
    c = AdminAPIClient(base_url=base, token="tok", allow_writes=True)
    with pytest.raises(BridgeError) as exc:
        c.announce("")
    assert "400" in str(exc.value)
