"""bridges.py - thin clients for ai_bridge (TCP JSON-RPC) and lsb_admin_api
(HTTP). Chharbot talks to these directly rather than going through MCP so the
local model path is self-contained (no Claude-in-the-loop required).

The two classes deliberately mirror the surface that mcp_ffxi_client and
mcp_ffxi_admin expose, so a future refactor that routes through MCP is a
drop-in replacement.
"""
from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, Optional


class BridgeError(RuntimeError):
    """Raised on any transport or protocol-level failure."""


# ---------- ai_bridge (TCP 127.0.0.1:27115) ----------------------------------

@dataclass
class AIBridgeClient:
    host: str = "127.0.0.1"
    port: int = 27115
    token: str = ""
    timeout: float = 5.0
    _sock: Optional[socket.socket] = None
    _id: int = 0
    _buf: bytes = b""

    def connect(self) -> None:
        if self._sock is not None:
            return
        s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self._sock = s
        self._buf = b""
        if self.token:
            # Handshake: ai_bridge expects {"auth":"<token>"} before any method.
            self._send_raw({"auth": self.token, "id": self._next_id()})
            resp = self._recv_one()
            if "error" in resp:
                raise BridgeError(f"auth rejected: {resp['error']}")

    def close(self) -> None:
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _send_raw(self, obj: Dict[str, Any]) -> None:
        assert self._sock is not None
        line = (json.dumps(obj) + "\n").encode("utf-8")
        self._sock.sendall(line)

    def _recv_one(self) -> Dict[str, Any]:
        """Block until one newline-terminated JSON object arrives."""
        assert self._sock is not None
        while b"\n" not in self._buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise BridgeError("ai_bridge closed connection")
            self._buf += chunk
        nl = self._buf.index(b"\n")
        line, self._buf = self._buf[:nl], self._buf[nl + 1:]
        try:
            return json.loads(line.decode("utf-8"))
        except ValueError as e:
            raise BridgeError(f"invalid JSON from ai_bridge: {e}") from e

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        self.connect()
        rid = self._next_id()
        self._send_raw({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        # Skip async event lines; return the first response that matches our id.
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            resp = self._recv_one()
            if resp.get("id") == rid:
                if "error" in resp:
                    raise BridgeError(f"{method}: {resp['error']}")
                return resp.get("result")
            # event line - discard silently for now
        raise BridgeError(f"{method}: timed out waiting for response")

    # Convenience wrappers - the set chharbot actually uses.
    def get_state(self) -> Dict[str, Any]:           return self.call("get_state")
    def get_chat_tail(self, n: int = 20) -> list:    return self.call("get_chat_tail", {"n": n})
    def get_entities(self, radius: int = 30) -> list: return self.call("get_entities", {"radius": radius})
    def get_inventory(self, bag: Optional[int] = None) -> list:
        return self.call("get_inventory", {"bag": bag} if bag is not None else {})
    def send_text(self, text: str) -> Dict[str, Any]: return self.call("send_text", {"text": text})
    def target(self, entity_id: int) -> Dict[str, Any]: return self.call("target", {"entity_id": entity_id})
    def ping(self) -> Dict[str, Any]:                 return self.call("ping")


# ---------- lsb_admin_api (HTTP 127.0.0.1:27116) -----------------------------

@dataclass
class AdminAPIClient:
    base_url: str = "http://127.0.0.1:27116"
    token: str = ""
    timeout: float = 10.0
    allow_writes: bool = False

    def _req(self, method: str, path: str, body: Optional[dict] = None) -> Any:
        url = self.base_url.rstrip("/") + path
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, method=method, data=data)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("X-Admin-Token", self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")
            raise BridgeError(f"{path}: HTTP {e.code}: {body_text}")
        except urllib.error.URLError as e:
            raise BridgeError(f"{path}: transport error: {e}")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError as e:
            raise BridgeError(f"{path}: invalid JSON response: {e}") from e

    # Reads
    def health(self) -> dict:                  return self._req("GET", "/health")
    def players(self) -> list:                 return self._req("GET", "/players")
    def player(self, pid: int) -> dict:        return self._req("GET", f"/players/{pid}")
    def zones(self) -> list:                   return self._req("GET", "/zones")
    def server_stats(self) -> dict:            return self._req("GET", "/server_stats")
    def event_tail(self, n: int = 200) -> dict: return self._req("GET", f"/events/tail?n={n}")
    def version_sync_status(self) -> dict:     return self._req("GET", "/version_sync/status")

    # Writes - all gated by self.allow_writes for an extra safety belt.
    def _assert_writes(self, op: str) -> None:
        if not self.allow_writes:
            raise BridgeError(f"{op}: writes disabled (pass allow_writes=True)")

    def announce(self, text: str) -> dict:
        self._assert_writes("announce")
        return self._req("POST", "/announce", {"text": text})

    def tell(self, to: str, text: str) -> dict:
        self._assert_writes("tell")
        return self._req("POST", "/tell", {"to": to, "text": text})

    def teleport(self, player: str, zone: int, x: float, y: float, z: float, rot: int = 0) -> dict:
        self._assert_writes("teleport")
        return self._req("POST", "/teleport",
                         {"player": player, "zone": zone, "x": x, "y": y, "z": z, "rot": rot})

    def version_sync_run(self, dry_run: bool = True, force: bool = False,
                         override_dll: Optional[str] = None, restart: bool = True) -> dict:
        self._assert_writes("version_sync_run")
        return self._req("POST", "/version_sync/run",
                         {"dry_run": dry_run, "force": force,
                          "override_dll": override_dll, "restart": restart})
