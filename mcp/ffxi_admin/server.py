"""mcp_ffxi_admin - MCP server wrapping the lsb_admin_api sidecar.

Every tool call issues a single HTTP request to the sidecar on
localhost:27116. Write tools require the admin token to be present in the
LSB_ADMIN_TOKEN env var (or read from LSB_ADMIN_TOKEN_FILE).

Install:
    pip install fastmcp httpx

Register in Claude's mcp.json:
    {
      "mcpServers": {
        "ffxi_admin": {
          "command": "python",
          "args": ["F:/ffxi/deploy/mcp/ffxi_admin/server.py"],
          "env": {
            "LSB_ADMIN_HOST": "127.0.0.1",
            "LSB_ADMIN_PORT": "27116",
            "LSB_ADMIN_TOKEN_FILE": "F:/ffxi/deploy/.lsb_admin_token"
          }
        }
      }
    }
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional

try:
    import httpx
    from fastmcp import FastMCP
except ImportError as exc:  # pragma: no cover
    raise SystemExit("pip install fastmcp httpx") from exc


HOST = os.environ.get("LSB_ADMIN_HOST", "127.0.0.1")
PORT = int(os.environ.get("LSB_ADMIN_PORT", "27116"))
BASE = f"http://{HOST}:{PORT}"
TIMEOUT = float(os.environ.get("LSB_ADMIN_TIMEOUT", "5.0"))


def _load_token() -> str:
    if os.environ.get("LSB_ADMIN_TOKEN"):
        return os.environ["LSB_ADMIN_TOKEN"]
    tf = os.environ.get("LSB_ADMIN_TOKEN_FILE")
    if tf and Path(tf).exists():
        return Path(tf).read_text(encoding="utf-8").strip()
    return ""


TOKEN = _load_token()

mcp = FastMCP("ffxi_admin")


def _headers() -> dict:
    h = {}
    if TOKEN:
        h["X-Admin-Token"] = TOKEN
    return h


def _get(path: str) -> Any:
    r = httpx.get(BASE + path, headers=_headers(), timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def _post(path: str, body: dict) -> Any:
    r = httpx.post(BASE + path, headers=_headers(), json=body, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


@mcp.tool()
def health() -> dict:
    """Health-check the lsb_admin_api sidecar."""
    return _get("/health")


@mcp.tool()
def list_players() -> list:
    """List characters on the server: id, name, main/sub job, zone, account."""
    return _get("/players")


@mcp.tool()
def get_player(player_id: int) -> dict:
    """Fetch one player's row by charid."""
    return _get(f"/players/{player_id}")


@mcp.tool()
def zones() -> list:
    """Zone population summary."""
    return _get("/zones")


@mcp.tool()
def server_stats() -> dict:
    """DB-wide stats: char count, account count, host/db."""
    return _get("/server_stats")


@mcp.tool()
def event_tail(n: int = 200) -> dict:
    """Tail the last N lines of the map_server log."""
    return _get(f"/events/tail?n={n}")


@mcp.tool()
def announce(text: str) -> dict:
    """Broadcast a server-wide announcement."""
    return _post("/announce", {"text": text})


@mcp.tool()
def tell(to: str, text: str) -> dict:
    """Send a private message to an online player."""
    return _post("/tell", {"to": to, "text": text})


@mcp.tool()
def teleport(player: str, zone: int, x: float, y: float, z: float, rot: int = 0) -> dict:
    """Teleport a player to a zone + coords."""
    return _post("/teleport", {
        "player": player, "zone": zone,
        "x": x, "y": y, "z": z, "rot": rot,
    })


@mcp.tool()
def give_item(player: str, item_id: int, count: int = 1) -> dict:
    """Give a player `count` copies of `item_id`."""
    return _post("/give_item", {"player": player, "item_id": item_id, "count": count})


@mcp.tool()
def spawn_mob(zone: int, mob_id: int, x: float, y: float, z: float, count: int = 1) -> dict:
    """Spawn `count` copies of a mob at the given zone+coords."""
    return _post("/spawn_mob", {
        "zone": zone, "mob_id": mob_id,
        "x": x, "y": y, "z": z, "count": count,
    })


@mcp.tool()
def kick(player: str, reason: str = "kicked by admin") -> dict:
    """Kick a player from the server."""
    return _post("/kick", {"player": player, "reason": reason})


# ---- version-sync tools (auto-match retail CLIENT_VER against login.lua) ----


@mcp.tool()
def version_sync_status() -> dict:
    """Show what CLIENT_VER is configured vs. what FFXiMain.dll contains.

    Returns fields: configured_client_ver, detected_client_ver, in_sync, drift,
    plus a human-readable status_report. No writes.
    """
    return _get("/version_sync/status")


@mcp.tool()
def version_sync_run(
    dry_run: bool = False,
    force: bool = False,
    override_dll: Optional[str] = None,
    restart: bool = True,
) -> dict:
    """Detect retail CLIENT_VER from FFXiMain.dll and auto-patch login.lua.

    Arguments:
      dry_run      - report what would change but don't write or restart.
      force        - skip the "only patch if retail is strictly newer" guard.
      override_dll - explicit path to FFXiMain.dll (bypasses candidate list).
      restart      - bounce login_server after a successful patch (default true).

    Returns a SyncResult dict including: ok, detected, previous_client_ver,
    new_client_ver, restart info, and message.
    """
    return _post("/version_sync/run", {
        "dry_run": dry_run,
        "force": force,
        "override_dll": override_dll,
        "restart": restart,
    })


if __name__ == "__main__":
    mcp.run()
