# lsb_admin_api — server-side AI control bridge

Small HTTP sidecar that exposes the LSB (LandSandBoat) server to Chharbot /
Claude via a localhost REST API on `127.0.0.1:27116`. The companion MCP
(`mcp/ffxi_admin/server.py`) wraps these endpoints as MCP tools.

Paired with `ai_bridge` (the Ashita addon, client-side) this lets the
assistant admin the world (announce, teleport, give item, kick, query DB)
without screenshots and without clicking around a GM console.

## Components

- `server.py` — FastAPI application. Read-only DB queries against LSB's
  MariaDB (same creds as `map_server.exe`), plus write endpoints that
  forward GM console commands through a Windows named pipe.
- `map_server_stdin_pump.py` — small wrapper that spawns `map_server.exe`
  with its stdin wired to `\\.\pipe\lsb_admin`; writing a line into that
  pipe injects a command into map_server's console interpreter.

## Install

```powershell
pip install fastapi uvicorn pymysql
```

Put a shared secret (any random string, ideally 32+ chars) into
`F:\ffxi\deploy\.lsb_admin_token` with NTFS ACLs restricting it to the
server account. Leave empty or delete the file to disable auth for
localhost-only testing.

## Run

First, swap out map_server.exe for the stdin pump:

```powershell
python F:\ffxi\deploy\sidecar\lsb_admin_api\map_server_stdin_pump.py F:\ffxi\server\map_server.exe
```

Then start the sidecar:

```powershell
set LSB_DB_HOST=127.0.0.1
set LSB_DB_USER=dspuser
set LSB_DB_PASS=...
set LSB_DB_NAME=dspdb
python F:\ffxi\deploy\sidecar\lsb_admin_api\server.py
```

Smoke-test:

```powershell
curl -s http://127.0.0.1:27116/health
curl -s -H "X-Admin-Token: $(Get-Content F:\ffxi\deploy\.lsb_admin_token)" http://127.0.0.1:27116/server_stats
```

## Endpoints

| Method | Path | Body | Notes |
|---|---|---|---|
| GET  | `/health` | — | Always public; returns `{ok, ts, has_token}` |
| GET  | `/players` | — | Lists chars from `chars` + `char_stats` |
| GET  | `/players/{pid}` | — | One row |
| GET  | `/zones` | — | Zone population |
| GET  | `/server_stats` | — | Counts |
| GET  | `/events/tail?n=N` | — | Tails `map_server.log` |
| POST | `/announce` | `{text}` | Broadcasts server-wide |
| POST | `/tell` | `{to, text}` | Private message |
| POST | `/teleport` | `{player, zone, x, y, z, rot}` | |
| POST | `/give_item` | `{player, item_id, count}` | |
| POST | `/spawn_mob` | `{zone, mob_id, x, y, z, count}` | |
| POST | `/kick` | `{player, reason}` | |

All write endpoints require header `X-Admin-Token: <secret>`.

## Security

Binds `127.0.0.1` only. Does not expose the DB password. The named pipe
is ACL'd to the same Windows account that runs `map_server.exe`. Writes
never touch the MariaDB directly — they go through LSB's own console
interpreter so LSB's own validation & logging apply.

## Limitations

- Console-command strings (`announce`, `sendToZone`, `addItem`,
  `spawnMob`, `kickPlayer`, `sendMessage`) are LSB's current defaults; if
  your fork renames any of those, edit the one-liner in `server.py`.
- Not all LSB forks ship with `sendMessage` for tells from console; some
  require an admin GM character to be online. For those, the MCP can
  always fall back to `ai_bridge.send_text` from a logged-in GM.
