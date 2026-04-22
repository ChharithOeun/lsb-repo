# FFXI AI Control MCPs

Two stateless MCP servers that let Claude / Chharbot see and drive the
FFXI private server without screenshots or simulated clicks.

| MCP | Wraps | Port | Role |
|---|---|---|---|
| `ffxi_client` | Ashita `ai_bridge` addon | `127.0.0.1:27115` | Per-character view: chat, entities, inventory, player state; and per-character actions: send chat, target |
| `ffxi_admin`  | LSB `lsb_admin_api` sidecar | `127.0.0.1:27116` | World view: player list, zone populations, DB snapshots; and world actions: announce, teleport, give-item, spawn-mob, kick |

See `docs/AI-CONTROL-ARCHITECTURE.md` for the design & rationale.

## Install

```powershell
pip install fastmcp httpx
```

For `ffxi_admin` you also need the sidecar running (see
`sidecar/lsb_admin_api/README.md`).

For `ffxi_client` you need the Ashita addon loaded
(`/addon load ai_bridge` from in-game; see `addons/ai_bridge/README.md`).

## Register with Claude

Copy `mcp/mcp.example.json` into your Claude config:

- Cowork: `~/.claude.json` under `mcpServers`
- Claude Code: `.claude/mcp.json` at the repo root

Fix the path in the `args` fields if your deploy prefix isn't
`F:\ffxi\deploy`.

## Smoke test

Once both bridges + MCPs are running, in Claude:

```
>>> Use ffxi_client.ping to confirm the in-game bridge is reachable.
>>> Use ffxi_admin.health to confirm the sidecar is reachable.
>>> Use ffxi_admin.server_stats to show me the current character count.
```

Expected: two healthy responses and a small dict with `chars` and
`accounts` counts.
