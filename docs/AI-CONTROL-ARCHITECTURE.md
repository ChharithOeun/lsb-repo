# AI Control Architecture — letting Chharbot/Claude see and drive FFXI

Goal: take Claude (and Chharbot) off of screenshots-and-clicks and give them a
proper, low-latency, structured view of the game and a structured way to act
on it. The right way to do this is **two bridges, two MCPs** — one at the
client side (what the player sees) and one at the server side (what the world
looks like). Each bridge is a tiny long-running process on the live Windows
box; each MCP is a stateless process that Claude/Chharbot spawns per session
and that talks to the bridge over localhost.

```
        +--------------------------------+       +------------------------------+
        | Claude / Chharbot MCP client   |       | Claude / Chharbot MCP client |
        +---------------+----------------+       +--------------+---------------+
                        | (stdio MCP)                          | (stdio MCP)
                        v                                      v
        +--------------------------------+       +------------------------------+
        | mcp_ffxi_client  (Python)      |       | mcp_ffxi_admin  (Python)     |
        |  exposes per-char tools        |       |  exposes world/admin tools   |
        +---------------+----------------+       +--------------+---------------+
                        | localhost:27115 JSON-RPC             | localhost:27116 HTTP
                        v                                      v
        +--------------------------------+       +------------------------------+
        | Ashita addon: ai_bridge        |       | LSB sidecar: lsb_admin_api   |
        |  (Lua, runs inside FFXi proc)  |       |  (Go/Python, next to LSB)    |
        |                                |       |                              |
        |  - chat tail buffer            |       |  - reads LSB MariaDB         |
        |  - entity list                 |       |  - writes to map_server      |
        |  - player state                |       |    stdin via named pipe      |
        |  - packet hooks                |       |  - runs GM commands          |
        |  - keystroke injector          |       |  - /announce, /give, /tele   |
        +--------------------------------+       +------------------------------+
                        ^                                      ^
                        | in-process                           | db + ipc
                        v                                      v
                +-------+------------+                +--------+---------+
                | FFXi client        |                | LSB map_server   |
                | (FFXiMain.dll)     |<-- network --->| + login_server   |
                +--------------------+                +------------------+
```

## Why two bridges

- **Client-side (ai_bridge addon)** sees what the player sees: chat log,
  targeted mob, buffs, inventory, current zone, XY coordinates, other
  entities within draw distance. It can also act *as the player*: target,
  cast a spell, move, use an item, reply to a tell. This is the only layer
  where "what does my guy see right now" makes sense.
- **Server-side (lsb_admin_api sidecar)** sees the world: every online
  player, every zone population, every GM event. It's the only layer where
  "teleport X to Y", "give item 12345 to player Kain", "announce a server
  reset" makes sense — those commands can't be driven from a single
  client's perspective.

Split cleanly and you can run both, one, or neither depending on the
session's goal. Playing the game as a character? ai_bridge. Running events
or admining? lsb_admin_api. Both, for a Chharbot that can both play and
admin? Both.

## Bridge 1 — Ashita `ai_bridge` addon

**Process model.** A regular Ashita v3 Lua addon, installed at
`F:\ffxi\Ashita\addons\ai_bridge\ai_bridge.lua`. Ashita loads it inside the
FFXi game process, so it has direct access to Ashita's world/party/entity
APIs without any packet parsing. It opens a TCP listener on `127.0.0.1:27115`
and accepts newline-delimited JSON-RPC 2.0 requests.

**Wire format.** Each request/response is one line of JSON:

```json
{"jsonrpc":"2.0","id":17,"method":"get_state","params":{}}
{"jsonrpc":"2.0","id":17,"result":{"zone":"Ru'Lude Gardens","x":12.3,"y":-4.1,"z":77.8,"hp_pct":98,"mp_pct":40,"target":null}}
```

**Tool surface (minimum viable).**

| Method | Params | Returns | Notes |
|---|---|---|---|
| `get_state` | — | `{zone, xyz, hp/mp/tp, facing, main/sub job, levels, buffs[], target_id}` | Single snapshot. Cheap. |
| `get_chat_tail` | `{n}` | `[{channel, speaker, text, ts}]` last N lines | Default 20. |
| `get_entities` | `{radius}` | `[{id, name, type, x, y, z, dist, hp_pct}]` | Players + NPCs + mobs within radius yalms. |
| `get_inventory` | `{bag}` | `[{slot, item_id, name, count}]` | All bags if bag omitted. |
| `send_text` | `{text}` | `{ok}` | Types into chat. Respects `/t`, `/p`, `/s` etc. prefixes. |
| `target` | `{entity_id}` | `{ok}` | Sets target. |
| `face` | `{yaw}` | `{ok}` | For screenshot angles. |
| `subscribe` | `{events: ["chat","damage"]}` | stream of JSON events | Push mode, one event per line. |

**Packet-hook events pushed to subscribed clients** (same connection, server
pushes lines without a request):

```json
{"event":"chat","channel":"say","speaker":"Kain","text":"heya"}
{"event":"damage","source":"Fire Elemental","target":"me","amount":420,"element":"fire"}
{"event":"zone_change","from":"Ru'Lude Gardens","to":"The Shrouded Maw"}
```

**Security.** Binds to `127.0.0.1` only. Optionally reads a shared token
from `settings.token` and rejects unauthenticated connections. No remote
exposure — the MCP that talks to it runs on the same machine.

## Bridge 2 — LSB `lsb_admin_api` sidecar

**Process model.** A small long-running process (Python FastAPI fine; Go if
you want zero deps) that sits alongside LSB's `map_server.exe` in the same
working directory and listens on `127.0.0.1:27116` for HTTP requests. It:

1. Has a read-only MariaDB connection to LSB's DB (same creds as the server).
2. Has a write path into `map_server`'s stdin via a Windows named pipe
   (`\\.\pipe\lsb_admin`), wired up by a one-line wrapper that runs
   `map_server.exe` with its stdin rebound to that pipe.
3. Knows LSB's GM command set (`@teleport`, `@addItem`, `@setJob`, etc.)
   and translates REST calls into console commands.

**Endpoints.**

| `GET /players` | list online: `[{id, name, job, zone, account_id}]` |
| `GET /players/{id}` | one player's full state (from DB + server push) |
| `GET /zones` | zone population summary |
| `POST /announce` | `{text}` — server-wide chat broadcast |
| `POST /tell` | `{to, text}` — private message to online player |
| `POST /teleport` | `{player, zone, xyz}` |
| `POST /give_item` | `{player, item_id, count}` |
| `POST /spawn_mob` | `{zone, mob_id, xyz, count}` |
| `POST /kick` | `{player, reason}` |
| `GET /server_stats` | uptime, cpu/mem, tick time |
| `GET /events/tail?n=200` | tail of map_server stdout |

**Auth.** HMAC token header `X-Admin-Token: <sha256 of shared secret>`.
Secret in `F:\ffxi\deploy\.lsb_admin_token`, 0600. Any 401 logs the source
IP and raises in the sidecar's structured log. Bound to localhost only.

## The two MCPs

Each is a small Python FastMCP server (single `server.py`) exposing the
bridge's surface as MCP tools. Schemas mirror the bridge's method list
one-for-one. Each tool call is: validate → forward to bridge → coerce the
response into a compact MCP content block. MCPs are stateless — they open a
fresh TCP/HTTP connection per call.

### `mcp_ffxi_client` (wraps `ai_bridge`)

Tools: `get_state`, `get_chat_tail`, `get_entities`, `get_inventory`,
`send_text`, `target`, `face`, `subscribe_events`. Stdio MCP, registered
in Claude's `mcp.json`.

### `mcp_ffxi_admin` (wraps `lsb_admin_api`)

Tools: `list_players`, `get_player`, `announce`, `tell`, `teleport`,
`give_item`, `spawn_mob`, `kick`, `server_stats`, `event_tail`. Stdio MCP.

## Why not just DIY packet parsing / direct memory reading?

- Ashita already has a robust, well-tested entity/world/packet API — we
  inherit all of it for free by writing an addon. No brittle memory offsets
  that break on every retail patch.
- LSB has a real live DB and a console interpreter with decades of GM
  commands. A sidecar that composes commands on top of that is thin and
  auditable.
- The *interesting* code is in the MCP layer — how tools are shaped, how
  subscribe events flow back, how the assistant reasons about them. Keep
  the bridges tiny.

## Deployment order

1. **ai_bridge stub addon** — opens the TCP listener, implements `get_state`
   and `get_chat_tail`. Proves the transport.
2. **mcp_ffxi_client stub** — exposes `get_state` + `get_chat_tail`. Proves
   the MCP wrap.
3. Expand addon method set. Add push-mode events.
4. **lsb_admin_api stub** — DB-only endpoints first (`/players`,
   `/server_stats`). Proves the DB path.
5. **mcp_ffxi_admin stub** — exposes those endpoints as tools.
6. Wire up the named-pipe stdin wrapper for map_server. Add write paths.

Each step is independently verifiable and reversible (delete the addon, kill
the sidecar — LSB and Ashita keep running).

## What success looks like for the next session

Claude, in a fresh chat:

```
>>> List my characters on this server and what jobs they're each wearing.
mcp_ffxi_admin.list_players() → [{"name":"Kain","job":"DRK/WAR", ...}, ...]

>>> I'm in Ru'Lude Gardens. Who else is in the zone and within 30 yalms?
mcp_ffxi_client.get_entities({"radius":30}) → [...]

>>> Send a shout asking if anyone wants to help me farm Dynamis.
mcp_ffxi_client.send_text({"text":"/sh LF help with Dynamis!"}) → {"ok":true}

>>> Drop me the current server announcement.
mcp_ffxi_admin.announce({"text":"Server reset in 10 min"}) → {"ok":true}
```

No screenshots, no clicks. That's the bar.
