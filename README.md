# FFXI + LandSandBoat — AI-controlled private server

Everything needed to run a LandSandBoat (LSB) FFXI private server that
(a) tracks retail's `CLIENT_VER` automatically, and (b) can be observed
and driven by Claude / Chharbot directly — no screenshots, no clicks.

This repo is the outcome of a multi-session build (2026-04-20 through
2026-04-21) that started from a broken guest-login path and ends with a
fully automatable private server. Each session's writeup is in
`docs/SESSION-*`.

## Subsystem map

```
repo/
├── addons/                      # in-process FFXI client plugins
│   ├── ai_bridge/                 JSON-RPC listener for client state/actions
│   └── xiloader_fixed/            Ashita addon that chain-loads xiloader 2.1.1
├── binaries/                    # verified xiloader 2.1.1 (MD5 44FE5F...)
├── chharbot/                    # NEW — local-LLM agent that drives the bridges
│   ├── chharbot/                  agent.py / tools.py / bridges.py / llm.py
│   ├── tests/                     24 pytests, offline (loopback sockets)
│   ├── bin/chharbot.ps1           Windows launcher
│   └── pyproject.toml
├── config/                      # Ashita profile references
├── docs/                        # design + session writeups
│   ├── AI-CONTROL-ARCHITECTURE.md
│   ├── SECURITY-REVIEW.md
│   ├── SESSION-2026-04-20-*.md
│   ├── SESSION-2026-04-21-v4-RETAIL-CHAIN-VERIFIED.md
│   ├── SESSION-2026-04-21-v5-AI-CONTROL-AND-VER-LOCK.md
│   ├── SESSION-2026-04-21-v6-VERSION-AUTO-MATCH.md
│   └── SESSION-2026-04-21-v7-CHHARBOT-LOCAL-AGENT.md
├── examples/                    # one-shot PowerShell deploy scripts
├── lsb_version_sync/            # auto-match retail CLIENT_VER
│   ├── lsb_version_sync/          Python package (scanner / patcher / reloader / sync)
│   ├── tests/                     27 pytests (22 functional + 5 security)
│   ├── bin/                       PowerShell wrapper + scheduled-task registrar
│   └── pyproject.toml             pip-installable
├── mcp/                         # MCPs Claude loads
│   ├── ffxi_client/               wraps ai_bridge (client-side)
│   ├── ffxi_admin/                wraps lsb_admin_api (server-side)
│   └── mcp.example.json
└── sidecar/
    └── lsb_admin_api/           # HTTP + named-pipe sidecar next to map_server.exe
```

## The three layers, at a glance

| Layer | What it sees | What it does | Where it runs |
|---|---|---|---|
| `ai_bridge` (Ashita addon, Lua) | player state, chat, entities, inventory | target, send chat, face | in-process with FFXiMain.dll |
| `lsb_admin_api` (FastAPI sidecar) | LSB DB, map_server log | announce, teleport, give-item, spawn-mob, kick, **version sync** | next to `map_server.exe` |
| `lsb_version_sync` (Python module) | `FFXiMain.dll` on disk | rewrites `login.lua` atomically + bounces `login_server` | scheduled task / sidecar / MCP / CLI |

All three are wrapped by MCP servers (`mcp/ffxi_client`, `mcp/ffxi_admin`)
so Claude / Chharbot can call them as tools in a fresh chat.

## "No clicks" bar

```
>>> ffxi_client.get_state                 # where am I / what am I doing
>>> ffxi_client.get_chat_tail {"n": 20}   # who said what
>>> ffxi_client.send_text {"text":"/sh LF help with Dynamis!"}
>>> ffxi_admin.list_players               # who's online
>>> ffxi_admin.announce {"text":"Server reset in 10 min"}
>>> ffxi_admin.version_sync_status        # retail vs configured
>>> ffxi_admin.version_sync_run           # auto-match CLIENT_VER
```

Every line above is a single MCP tool call. No screenshots parsed, no
pixels clicked.

## Runbook — cold install

```powershell
# 1. Stage this repo on the live box.
git clone <this repo> F:\ffxi\deploy\repo

# 2. Bring the retail loader chain up (first time only).
powershell -NoProfile -ExecutionPolicy Bypass `
  -File F:\ffxi\deploy\repo\examples\install-xiloader-2.1.1.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File F:\ffxi\deploy\repo\examples\finish5.ps1

# 3. Install the AI-control bridges and MCPs.
powershell -NoProfile -ExecutionPolicy Bypass `
  -File F:\ffxi\deploy\repo\examples\deploy-ai-control.ps1

# 4. Install + schedule the version-sync module.
pip install -e F:\ffxi\deploy\repo\lsb_version_sync
powershell -NoProfile -ExecutionPolicy Bypass `
  -File F:\ffxi\deploy\repo\lsb_version_sync\bin\register-scheduled-task.ps1

# 5. Merge mcp/mcp.example.json into your Claude config.
```

From then on: a retail patch from SE triggers a FFXiMain.dll change; the
scheduled task picks up the new CLIENT_VER within 6 hours; login.lua is
patched; login_server is bounced; next login works. If you want it
instantaneous, call `ffxi_admin.version_sync_run` from Claude.

## Session history (short)

- **v1-v2** (2026-04-20) — diagnosed and fixed the guest-password hash;
  identified the xiloader-version floor.
- **v3** (2026-04-20) — installed verified xiloader 2.1.1 binary
  (MD5 `44FE5F23BF76E4E847946B5B76F1E061`) with a versioned backup.
- **v4** (2026-04-21) — proved end-to-end retail chain: xiloader →
  FFXiMain.dll → live FFXI window; stopped at FFXI-3331.
- **v5** (2026-04-21) — designed the two-bridge AI control architecture
  and landed stub addons, sidecar, MCPs, and a one-shot `VER_LOCK=0`
  patch script.
- **v6** (2026-04-21) — built `lsb_version_sync`: the first community
  solution that auto-matches retail `CLIENT_VER` into LSB's
  `login.lua`. No manual edits on every SE patch, ever again.
- **v7** (2026-04-21) — shipped `chharbot/`, a local-model agent that
  drives both bridges directly (Ollama or OpenAI-compatible; no Claude
  required), plus a 10-finding security pass over the v5+v6 stack
  (`docs/SECURITY-REVIEW.md`). 51 tests green across both packages.

See `docs/` for the full writeups and `docs/AI-CONTROL-ARCHITECTURE.md`
for the design rationale.

## License

MIT for original code in this repo. xiloader and Ashita are the property
of their respective authors; this repo bundles `xiloader-2.1.1.exe`
unchanged, with MD5 published for tamper-checking.
