"""demo-chharbot.py - exercise chharbot's agent loop end-to-end in the sandbox.

Stands up:
  * a fake ai_bridge on a random TCP port (newline-delimited JSON-RPC)
  * a fake lsb_admin_api on a random HTTP port (canned JSON)
  * a scripted "LLM" that returns pre-baked tool_call sequences

Then drives chharbot through four scenarios and prints the final answers
plus the tool-call trace for each. Proves the wiring works without needing
the Windows box, Ollama, or a real LSB process.

Run: PYTHONPATH=/sessions/.../FFXI/repo python3 demo-chharbot.py
"""
from __future__ import annotations

import http.server
import json
import socket
import socketserver
import threading
import time
from typing import Any, Dict, List, Tuple

from chharbot.agent import Agent, AgentConfig
from chharbot.bridges import AIBridgeClient, AdminAPIClient
from chharbot.llm import LLMClient


# ---------- fake ai_bridge TCP server ---------------------------------------

class FakeAIBridge(threading.Thread):
    def __init__(self, state: Dict[str, Any]):
        super().__init__(daemon=True)
        self.state = state
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]
        self._stop = False

    def run(self):
        while not self._stop:
            try:
                self.sock.settimeout(0.5)
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket):
        buf = b""
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    req = json.loads(line)
                    method = req.get("method")
                    rid = req.get("id")
                    if method is None:
                        # auth handshake
                        resp = {"id": rid, "ok": True}
                    elif method == "ping":
                        resp = {"id": rid, "result": {"pong": True, "t": time.time()}}
                    elif method == "get_state":
                        resp = {"id": rid, "result": self.state["state"]}
                    elif method == "get_chat_tail":
                        resp = {"id": rid, "result": self.state["chat"]}
                    elif method == "get_entities":
                        resp = {"id": rid, "result": self.state["entities"]}
                    elif method == "get_inventory":
                        resp = {"id": rid, "result": self.state.get("inventory", [])}
                    elif method == "send_text":
                        self.state.setdefault("chat_sent", []).append(req.get("params", {}))
                        resp = {"id": rid, "result": {"ok": True}}
                    else:
                        resp = {"id": rid, "error": f"unknown method {method}"}
                    conn.sendall((json.dumps(resp) + "\n").encode())
        except ConnectionResetError:
            pass

    def stop(self):
        self._stop = True
        try:
            self.sock.close()
        except OSError:
            pass


# ---------- fake lsb_admin_api HTTP server ----------------------------------

class FakeAdminAPIHandler(http.server.BaseHTTPRequestHandler):
    state: Dict[str, Any] = {}  # set by factory

    def log_message(self, *a, **kw):  # silence access log
        pass

    def _send(self, code: int, body: Any):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth_ok(self) -> bool:
        return self.headers.get("X-Admin-Token") == self.state.get("token")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._send(200, {"ok": True, "ts": int(time.time()), "has_token": True})
        if not self._auth_ok():
            return self._send(401, {"detail": "bad token"})
        if path == "/server_stats":
            return self._send(200, self.state["server_stats"])
        if path == "/players":
            return self._send(200, self.state["players"])
        if path == "/zones":
            return self._send(200, self.state["zones"])
        if path == "/version_sync/status":
            return self._send(200, self.state["vsync_status"])
        return self._send(404, {"detail": "nope"})

    def do_POST(self):
        if not self._auth_ok():
            return self._send(401, {"detail": "bad token"})
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        self.state.setdefault("writes", []).append((self.path, body))
        return self._send(200, {"ok": True, "echo": body})


def start_fake_admin(state: Dict[str, Any]) -> Tuple[str, socketserver.TCPServer]:
    handler = type("H", (FakeAdminAPIHandler,), {"state": state})
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
    srv.allow_reuse_address = True
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    host, port = srv.server_address
    return f"http://{host}:{port}", srv


# ---------- scripted LLM ----------------------------------------------------

class ScriptedLLM(LLMClient):
    """Replays a pre-baked sequence of LLM turns. Each turn is either a list of
    tool_call dicts or a final-answer string."""

    def __init__(self, script: List[Any]):
        super().__init__(base_url="mem://scripted", model="scripted")
        self.script = list(script)
        self.turns_seen = 0

    def chat(self, messages, tools=None, temperature=0.2):
        self.turns_seen += 1
        if not self.script:
            return {"content": "(scripted LLM exhausted)", "tool_calls": [], "raw": {}}
        turn = self.script.pop(0)
        if isinstance(turn, str):
            return {"content": turn, "tool_calls": [], "raw": {}}
        # list of (name, args_dict)
        calls = [
            {"id": f"c{self.turns_seen}_{i}", "name": name, "arguments": json.dumps(args)}
            for i, (name, args) in enumerate(turn)
        ]
        return {"content": None, "tool_calls": calls, "raw": {}}


# ---------- scenarios -------------------------------------------------------

def make_state() -> Dict[str, Any]:
    return {
        "token": "test-admin-token",
        "state": {
            "player": {"name": "Chharith", "zone": 230, "hp": 840, "mp": 120, "pos": {"x": 34.2, "y": 0.1, "z": -12.8}},
            "target": None, "in_combat": False,
        },
        "chat": [
            {"ts": 1700000000, "channel": "say", "speaker": "Chharith", "text": "anyone on?"},
            {"ts": 1700000005, "channel": "shout", "speaker": "GM_Bob", "text": "server's up"},
        ],
        "entities": [
            {"id": 0x17000001, "name": "Goblin_Smithy", "kind": "mob", "distance": 8.2},
            {"id": 0x17000002, "name": "GUESTCL1",     "kind": "player", "distance": 1.0},
        ],
        "server_stats": {
            "uptime_sec": 3921, "online_players": 3, "zones_active": 12,
            "map_server_pid": 4220, "login_server_pid": 4210,
        },
        "players": [
            {"id": 1, "name": "Chharith", "zone": 230, "job": "WAR", "level": 75, "online": True},
            {"id": 2, "name": "GUESTCL1", "zone": 230, "job": "WHM", "level": 50, "online": True},
        ],
        "zones": [{"id": 230, "name": "San d'Oria-Port", "population": 2}],
        "vsync_status": {
            "login_lua_version": "20251015_1",
            "retail_version":    "20251015_1",
            "in_sync": True,
            "ver_lock_mode": 2,
            "last_run_ts": 1700000100,
        },
    }


def scenario_1_server_stats(state):
    """Read-only: 'What are the current server stats?'"""
    script = [
        [("server_stats", {})],
        "Server has been up 65 minutes, 3 players online across 12 active zones; map_server pid 4220.",
    ]
    return script, "What are the current server stats?"


def scenario_2_vsync(state):
    """Read-only: 'Is login.lua in sync with the retail client?'"""
    script = [
        [("version_sync_status", {})],
        "Yes - login.lua and the retail client both report 20251015_1, ver_lock_mode=2, last check was on boot.",
    ]
    return script, "Is login.lua in sync with the retail client on this box?"


def scenario_3_zones(state):
    """Read-only: 'How many zones have characters in them?'"""
    script = [
        [("server_zones", {})],
        "1 zone has players in it right now: San d'Oria-Port (2 online).",
    ]
    return script, "How many zones have characters in them?"


def scenario_4_multi_step(state):
    """Read + compose: get state, then chat tail, then answer."""
    script = [
        [("client_get_state", {})],
        [("client_get_chat_tail", {"n": 10})],
        "You're on Chharith in San d'Oria-Port at (34.2, 0.1, -12.8), not in combat. "
        "Latest chat: GM_Bob shouted 'server's up' five seconds after your /say.",
    ]
    return script, "Where am I and what's happening around me?"


def scenario_5_unknown_tool(state):
    """Resilience: model invents a tool that doesn't exist, then recovers."""
    script = [
        [("totally_made_up_tool", {"foo": 1})],
        "I don't have a tool for that - try asking about server stats, zones, or /version_sync status.",
    ]
    return script, "Nuke the server."


def scenario_6_write_gate(state):
    """Safety: model tries to /announce with allow_writes=False; dispatch refuses."""
    script = [
        [("server_announce", {"text": "server restart in 5 minutes"})],
        "I can't broadcast announcements - writes are disabled for this session. "
        "Ask an operator to re-run with --allow-writes if this is authorized.",
    ]
    return script, "Announce that the server is restarting in 5 minutes."


# ---------- driver ----------------------------------------------------------

def run_scenarios():
    state = make_state()

    bridge = FakeAIBridge(state); bridge.start()
    admin_url, admin_srv = start_fake_admin(state)

    ai = AIBridgeClient(host="127.0.0.1", port=bridge.port, token="")
    admin = AdminAPIClient(base_url=admin_url, token=state["token"], allow_writes=False)

    # quick sanity
    print(f"=== fake backends up ===")
    print(f"  ai_bridge  : 127.0.0.1:{bridge.port}")
    print(f"  admin_api  : {admin_url}")
    print(f"  health     : {admin.health()}")
    print()

    scenarios = [
        ("1. server_stats",           scenario_1_server_stats),
        ("2. version_sync status",    scenario_2_vsync),
        ("3. zones / players",        scenario_3_zones),
        ("4. multi-step state+chat",  scenario_4_multi_step),
        ("5. unknown-tool recovery",  scenario_5_unknown_tool),
        ("6. write-gate refusal",     scenario_6_write_gate),
    ]
    for title, builder in scenarios:
        script, prompt = builder(state)
        llm = ScriptedLLM(script)
        agent = Agent(AgentConfig(llm=llm, ai=ai, admin=admin, allow_writes=False))
        print(f"--- {title} ---")
        print(f">>> {prompt}")
        res = agent.run(prompt)
        for tc in res["tool_calls"]:
            out_preview = json.dumps(tc["result"])[:120]
            print(f"  [tool] {tc['name']}({tc['arguments']}) -> {out_preview}")
        print(f"<<< {res['content']}")
        print(f"    (steps={res['steps']})")
        print()

    # tidy up
    admin_srv.shutdown()
    bridge.stop()
    print("=== done ===")


if __name__ == "__main__":
    run_scenarios()
