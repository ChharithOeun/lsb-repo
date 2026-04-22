# ai_bridge — Ashita addon for AI control of FFXI

An Ashita v3 Lua addon that runs inside the FFXI client process and exposes a
JSON-RPC 2.0 listener on `127.0.0.1:27115`. The companion MCP
(`mcp/ffxi_client/server.py`) forwards Claude/Chharbot tool calls here, so the
assistant can observe the game (chat, entities, inventory, player state) and
act as the player (send chat, target, face) without screenshots or simulated
clicks.

See `docs/AI-CONTROL-ARCHITECTURE.md` in the repo root for the full design and
the companion `lsb_admin_api` sidecar that covers server-side control.

## Install

1. Copy the whole `addons/ai_bridge` folder to
   `F:\ffxi\Ashita\addons\ai_bridge` on the live box.
2. In Ashita's chat window:

   ```
   /addon load ai_bridge
   ```

   You should see `[ai_bridge] listening on 127.0.0.1:27115`.
3. Verify from a second terminal:

   ```powershell
   $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 27115)
   $s = $c.GetStream()
   $w = New-Object System.IO.StreamWriter($s); $w.NewLine = "`n"; $w.AutoFlush = $true
   $r = New-Object System.IO.StreamReader($s)
   $w.WriteLine('{"jsonrpc":"2.0","id":1,"method":"ping"}')
   $r.ReadLine()
   ```

   Expect: `{"jsonrpc":"2.0","id":1,"result":{"pong":true,"ts":...}}`

## Methods

| Method | Params | Result | Notes |
|---|---|---|---|
| `ping` | — | `{pong, ts}` | Health check. |
| `get_state` | — | `{name,zone_id,hp,hp_max,mp,mp_max,tp,main_job,sub_job,main_level,sub_level,x,y,z,target_id}` | Single snapshot. |
| `get_chat_tail` | `{n}` | `[{mode,text,ts}, ...]` | Last N chat lines (default 20). |
| `get_entities` | `{radius}` | `[{id,idx,name,type,hp_pct,x,y,z,dist}, ...]` | Yalms within radius (default 30). |
| `get_inventory` | `{bag}` | `[{bag,slot,item_id,name,count}, ...]` | All bags if bag omitted. |
| `send_text` | `{text}` | `{ok}` | Queues a chat/command line (respects `/t`, `/p`, `/s` prefixes). |
| `target` | `{entity_id}` | `{ok}` | Issues `/ta`. |
| `face` | `{yaw}` | `{ok,stub:true}` | Stubbed; needs memory write. |
| `subscribe` | `{events}` | `{ok,events}` | Enables push-mode for `chat` (and later `damage`, `zone_change`). |

## In-game commands

- `/aibridge status` (or `/aib status`) — show connected clients + chat-tail depth.
- `/aib kick` — disconnect all clients.

## Security

Listener binds to `127.0.0.1` only. If you want local-process auth anyway,
set `token = '<something>'` in `settings/settings.lua` — the first line the
client sends must then be `{"auth":"<token>"}`.

## Limitations

This is the stub implementation: state is read-only correct, action methods
(`target`, `face`) route through Ashita chat commands rather than direct
memory writes. Packet-hook events (`damage`, `zone_change`) are not yet
wired up. The architecture doc calls out what each future milestone adds.
