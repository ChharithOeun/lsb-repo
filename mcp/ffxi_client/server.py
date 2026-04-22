"""mcp_ffxi_client - MCP server wrapping the Ashita ai_bridge addon.

Stateless wrapper: every tool call opens a fresh TCP connection to the
ai_bridge listener on localhost:27115, sends a single JSON-RPC 2.0 request,
reads a single response line, and returns the result.

Install deps:
    pip install fastmcp

Register in Claude's mcp.json (Cowork or Claude Code):
    {
      "mcpServers": {
        "ffxi_client": {
          "command": "python",
          "args": ["F:/ffxi/deploy/mcp/ffxi_client/server.py"],
          "env": {"AI_BRIDGE_HOST": "127.0.0.1", "AI_BRIDGE_PORT": "27115"}
        }
      }
    }
"""
from __future__ import annotations

import json
import os
import socket
from typing import Any, Optional

try:
    from fastmcp import FastMCP
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "fastmcp not installed. Run: pip install fastmcp"
    ) from exc


HOST = os.environ.get("AI_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("AI_BRIDGE_PORT", "27115"))
TOKEN = os.environ.get("AI_BRIDGE_TOKEN", "")
TIMEOUT = float(os.environ.get("AI_BRIDGE_TIMEOUT", "3.0"))

mcp = FastMCP("ffxi_client")

_next_id = 0


def _rpc(method: str, params: Optional[dict] = None) -> Any:
    """Open a socket, send one JSON-RPC request, return the result or raise."""
    global _next_id
    _next_id += 1
    req = {"jsonrpc": "2.0", "id": _next_id, "method": method, "params": params or {}}

    with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as s:
        s.settimeout(TIMEOUT)
        f = s.makefile("rwb", buffering=0)

        if TOKEN:
            f.write((json.dumps({"auth": TOKEN}) + "\n").encode("utf-8"))

        f.write((json.dumps(req) + "\n").encode("utf-8"))

        # Read lines until we get the response matching our id (skipping push
        # events, which may arrive interleaved on subscribed connections).
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError(f"ai_bridge closed connection before responding to {method}")
            try:
                resp = json.loads(line.decode("utf-8").strip())
            except json.JSONDecodeError:
                continue
            if resp.get("event"):
                continue  # push event on an unrelated connection; ignore
            if resp.get("id") != req["id"]:
                continue
            if "error" in resp:
                raise RuntimeError(f"{method}: {resp['error']}")
            return resp.get("result")


@mcp.tool()
def ping() -> dict:
    """Health-check the ai_bridge addon; returns {pong, ts} on success."""
    return _rpc("ping")


@mcp.tool()
def get_state() -> dict:
    """Snapshot the player's current state: zone, position, HP/MP/TP, jobs, target."""
    return _rpc("get_state")


@mcp.tool()
def get_chat_tail(n: int = 20) -> list:
    """Return the last N chat lines seen by the client (default 20)."""
    return _rpc("get_chat_tail", {"n": n})


@mcp.tool()
def get_entities(radius: float = 30.0) -> list:
    """List entities (players, NPCs, mobs) within `radius` yalms of the player."""
    return _rpc("get_entities", {"radius": radius})


@mcp.tool()
def get_inventory(bag: Optional[int] = None) -> list:
    """List items in `bag` (0=inventory, 8/10/11/12=wardrobes). All bags if bag omitted."""
    params = {}
    if bag is not None:
        params["bag"] = bag
    return _rpc("get_inventory", params)


@mcp.tool()
def send_text(text: str) -> dict:
    """Queue a chat/command line exactly as if the player typed it.

    Prefix with /s, /t, /p, /sh, /l1, /l2 etc. to choose the channel;
    unprefixed text goes to /say by default.
    """
    return _rpc("send_text", {"text": text})


@mcp.tool()
def target(entity_id: int) -> dict:
    """Target the given entity by its server id."""
    return _rpc("target", {"entity_id": entity_id})


@mcp.tool()
def face(yaw: float) -> dict:
    """Face a yaw angle (radians). STUB in the current addon release."""
    return _rpc("face", {"yaw": yaw})


if __name__ == "__main__":
    mcp.run()
