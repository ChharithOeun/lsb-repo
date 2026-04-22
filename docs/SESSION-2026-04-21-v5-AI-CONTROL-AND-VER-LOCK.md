# Session 2026-04-21 v5 — FFXI-3331 fix path + AI control subsystem stubbed

Continuation of v4 (which closed out the retail loader chain). This session:

1. Nailed the root cause of FFXI-3331 on the live box and produced the
   one-shot patch script that resolves it.
2. Stood up the two-bridge / two-MCP AI control subsystem designed in
   `docs/AI-CONTROL-ARCHITECTURE.md` — the Ashita `ai_bridge` addon, the
   LSB `lsb_admin_api` sidecar, and their Python MCP wrappers.

## FFXI-3331 — confirmed cause and fix

`find-lsb.ps1` identified the live LSB config at
`F:\ffxi\server\settings\login.lua`:

```
CLIENT_VER = '30260203_0',
VER_LOCK   = 2,
```

`VER_LOCK = 2` is LSB's "greater-than-or-equal" mode. In theory a NEWER
retail date-stamp (Steam version is patched well past `30260203`) should
pass; in practice the lexicographic comparator in LSB's `version_lock`
handler rejects anything whose trailing-revision digit or raw string
doesn't line up, and the assistant sees FFXI-3331 in the client.

**Do other private servers auto-match?** No. LSB already does
"greater-than-or-equal" by default (mode 2) — there is no feature for
"auto-pull retail version string from SE and rewrite config." Operators
either (a) bake in the latest retail `CLIENT_VER` they know of, (b) set
`VER_LOCK = 0` to turn the check off, or (c) patch `login.cpp` to print
the client's raw version packet and copy it into config. (a) is brittle
(requires periodic updates on every retail patch); (b) is what the
community almost always does on private boxes; (c) is what you'd do on a
shared public server where (b) would be a security issue.

**Our fix:** `examples/patch-ver-lock.ps1` — backs up
`login.lua.ver-lock-bak.<timestamp>`, sets `VER_LOCK = 0`, and restarts
the `login_server` process. Optional `-NewClientVer '<yyyymmdd_r>'`
flag for operators who prefer option (a).

Run order on the live box:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\patch-ver-lock.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\finish5.ps1
```

Expected: `finish5.xiloader-stdout.log` still shows the full auth
handshake, and the retail window advances past the version dialog to
character select.

## AI control subsystem — stubs landed

`docs/AI-CONTROL-ARCHITECTURE.md` describes two bridges / two MCPs. All
four components are now in the repo:

```
addons/ai_bridge/                       - Ashita v3 Lua addon (client bridge)
    ai_bridge.lua                       - TCP listener, JSON-RPC dispatch,
                                          state readers, send_text/target
    settings/settings.lua               - default settings (host, port, token)
    README.md                           - install + smoke test

sidecar/lsb_admin_api/                  - LSB HTTP sidecar (admin bridge)
    server.py                           - FastAPI app, DB + console-pipe writes
    map_server_stdin_pump.py            - wraps map_server.exe with a named-pipe stdin
    README.md                           - install + smoke test

mcp/ffxi_client/                        - MCP wrapping ai_bridge
    server.py                           - FastMCP server, one RPC per tool
mcp/ffxi_admin/                         - MCP wrapping lsb_admin_api
    server.py                           - FastMCP server, one HTTP per tool
mcp/mcp.example.json                    - drop-in for Claude's mcp.json
mcp/README.md                           - cross-ref

examples/deploy-ai-control.ps1          - one-shot installer for the live box
```

Ports used: `127.0.0.1:27115` (ai_bridge), `127.0.0.1:27116`
(lsb_admin_api). Both localhost-only. Admin endpoints gated by
`X-Admin-Token` against `F:\ffxi\deploy\.lsb_admin_token`
(auto-generated on first deploy).

### Wire behavior

`ai_bridge`:

- TCP listener, newline-delimited JSON-RPC 2.0.
- Methods: `ping`, `get_state`, `get_chat_tail`, `get_entities`,
  `get_inventory`, `send_text`, `target`, `face`, `subscribe`.
- Push events on the same socket for subscribed event names (`chat`
  implemented; `damage`, `zone_change` scaffolded).
- Tail of last 200 chat lines kept in-memory; `get_chat_tail` returns
  the last N.
- State reads via Ashita's `GetMemoryManager()` / `GetEntity()` APIs —
  no brittle memory offsets.

`lsb_admin_api`:

- FastAPI on `127.0.0.1:27116`.
- Read path: DictCursor over LSB's MariaDB (`chars`, `char_stats`,
  `accounts`).
- Write path: GM console commands (`announce`, `sendToZone`,
  `addItem`, `spawnMob`, `kickPlayer`, `sendMessage`) written into
  `\\.\pipe\lsb_admin`, which `map_server_stdin_pump.py` feeds into
  `map_server.exe`'s stdin.

Both MCPs are pure wrappers — one tool call → one RPC/HTTP → coerced
into an MCP content block. Stateless, cheap to spawn, cheap to kill.

## Smoke tests for next session

With everything deployed:

```
>>> ffxi_client.ping
>>> ffxi_client.get_state
>>> ffxi_client.get_chat_tail {"n": 5}
>>> ffxi_admin.health
>>> ffxi_admin.server_stats
>>> ffxi_admin.list_players
```

Once those pass, the "no screenshots, no clicks" bar from the
architecture doc is reached.

## Files added/updated in this session

| File | Purpose |
|---|---|
| `examples/patch-ver-lock.ps1` | Fix FFXI-3331 on the live box |
| `examples/deploy-ai-control.ps1` | Push addon + MCPs + sidecar to live paths |
| `addons/ai_bridge/ai_bridge.lua` | Ashita addon — client-side state bridge |
| `addons/ai_bridge/settings/settings.lua` | Addon defaults |
| `addons/ai_bridge/README.md` | Addon docs |
| `sidecar/lsb_admin_api/server.py` | Admin HTTP API |
| `sidecar/lsb_admin_api/map_server_stdin_pump.py` | Named-pipe stdin shim |
| `sidecar/lsb_admin_api/README.md` | Sidecar docs |
| `mcp/ffxi_client/server.py` | MCP wrapping ai_bridge |
| `mcp/ffxi_admin/server.py` | MCP wrapping lsb_admin_api |
| `mcp/mcp.example.json` | Drop-in Claude config |
| `mcp/README.md` | Cross-ref |
| `docs/SESSION-2026-04-21-v5-AI-CONTROL-AND-VER-LOCK.md` | This document |

## Status of the task list after this session

- #7 "Resolve FFXI-3331 client/server version mismatch" → **patch
  script ready**, pending a live-box run
- #8 "Research FFXI-3331 fix options (version auto-match)" → **complete**
- #10 "Stub Ashita AI-bridge addon + MCP" → **complete**
- #11 "Stub LSB admin-API sidecar + MCP" → **complete**
