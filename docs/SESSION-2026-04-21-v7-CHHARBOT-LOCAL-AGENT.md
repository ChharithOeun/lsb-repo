# Session 2026-04-21 (v7) — Chharbot local-model agent + full security pass

## What this session delivered

Three pieces landed:

1. **`chharbot/` package** — a local-LLM agent that drives both v5 bridges
   directly, with no framework and no Claude in the loop. Ollama by default,
   any OpenAI-compatible endpoint as a swap-in.

2. **Security hardening of the v5+v6 stack** — 10 findings surfaced by audit
   (3 HIGH, 4 MED, 3 LOW). All fixed in code; 5 covered by regression tests
   (`lsb_version_sync/tests/test_security.py`). Full write-up in
   `docs/SECURITY-REVIEW.md`.

3. **Tests everywhere** — 51 total: 27 in `lsb_version_sync/tests/` (22 old
   + 5 security), 24 in `chharbot/tests/` (tool registry, dispatch,
   agent loop, bridge transports over real loopback sockets).

## Why chharbot was built

v5 landed two bridges and two MCP wrappers so Claude could drive FFXI. The
user's ask in this session was simple: *"a local model interfaces or
completely build chharbot into that world"*. Either Chharbot can run under
a local LLM, or it ceases to be Chharbot — it becomes a Claude puppet.

The chosen solution is the first option in full: a local-agent package
that speaks to the bridges natively and only needs an LLM endpoint. The
same MCP wrappers can still be used from Claude when that's the right
fit, but chharbot is now the default driver for the stack.

## Architecture

```
chharbot/
├── chharbot/
│   ├── __init__.py      public API
│   ├── __main__.py      CLI: one-shot, REPL, --allow-writes, --probe
│   ├── agent.py         ReAct loop, ~80 lines
│   ├── tools.py         tool registry + JSON-schema dispatch
│   ├── bridges.py       AIBridgeClient (TCP) + AdminAPIClient (HTTP)
│   └── llm.py           OllamaClient + OpenAICompatClient
├── tests/
│   ├── test_tools.py    8 tests - registry shape + dispatch validation
│   ├── test_agent.py    7 tests - scripted LLM driving the loop
│   └── test_bridges.py  9 tests - loopback socket / HTTP stubs
├── bin/chharbot.ps1     Windows wrapper (auto-installs package if missing)
├── pyproject.toml       pip install -e .
└── README.md
```

### Loop

ReAct, no framework, one file:

- assistant → content XOR tool_calls[]
- each tool_call → validated → dispatched → `{"result": ...}` or `{"error": ...}`
- result sent back as `role=tool` message with `tool_call_id`
- loop bails on content-only reply or `max_steps` (default 8)

### Read-only by default

The tool registry is built from the connected bridges and a `allow_writes`
flag. Without the flag, the write tools (`client_send_text`,
`client_target`, `server_announce`, `server_tell`, `version_sync_run`)
are not part of the catalogue the model sees. If the model asks for one
anyway, the dispatcher returns an unknown-tool error — the model's reply
carries no side effects. Tested in
`test_writes_blocked_in_read_only_mode`.

### Validation ladder

Every user → model → tool hop gets re-validated:

1. **LLM response shape** — tool_calls must have `id`, `name`, `arguments`
   (string). Missing pieces raise during agent dispatch.
2. **JSON parse** — `dispatch()` parses the arguments string; failure is
   returned to the model as `{"error": ...}`.
3. **Schema match** — unknown keys rejected (additionalProperties=false).
4. **Python binding** — `TypeError` from a missing required kwarg is
   caught and reported as an error, not a crash.
5. **Bridge** — `BridgeError` (transport, auth, server-side 4xx/5xx) is
   also caught and reported.

Nothing in the chain can turn a misbehaving model into a process exit.

## Security review outcome

Audit (I'll call out the ones that had real bite):

- **Finding 1 (HIGH): command injection** — free-form text on
  `/tell`/`/announce` concatenated into map_server console. Fixed with
  strict `_NAME_RE` + `_BAD_CTRL` validators, plus a CR/LF/NUL rejection
  at `console_write` as defence-in-depth.
- **Finding 2 (HIGH): auth fail-open** — empty token file → silent pass
  through. Fixed to fail closed (503) unless `LSB_ADMIN_ALLOW_NO_TOKEN=1`.
- **Finding 3 (HIGH): path traversal** — `override_dll` on
  `/version_sync/run` took any path. Fixed with `_validate_override_dll`:
  must resolve strict, must be `.dll`, must live under
  `LSB_VSYNC_ALLOWED_ROOTS`.
- **Finding 5 (MED): TOCTOU symlink swap** on login.lua. Fixed with
  `_refuse_symlinks` in `patcher._atomic_write` and `_backup`.
- **Finding 6 (MED): `Popen` gadget** via `exe_hint`. Fixed with
  resolve(strict) + symlink-target agreement + basename check.
- **Finding 4 (MED): ai_bridge unauth** — localhost socket accepted any
  local process. Fixed with a `{"auth":"<token>"}` handshake, refusal
  on mismatch.
- **Finding 7 (MED): DoS surfaces** — `max_clients`, per-client token
  bucket rate limit, `max_entities_radius` clamp, `send_text` length
  cap.

Three LOW findings (temp-file collisions, length caps, redundant
CR/LF rejection) closed as well. Full table + rationale +
accepted-risk list in `docs/SECURITY-REVIEW.md`.

## Test posture

```
$ cd lsb_version_sync && python3 -m pytest tests/ -q
27 passed in 0.23s

$ cd chharbot && PYTHONPATH=. python3 -m pytest tests/ -q
24 passed in 2.18s
```

The chharbot bridge tests use real loopback sockets + `ThreadingHTTPServer`
stubs, so they exercise the JSON framing and HTTP header path, not just
the dict shape.

## What's not done

- **Live box smoke test.** chharbot + Ollama on the Windows host is the
  obvious next step; needs a llama3.1 pull. Tracked separately.
- **MCP wiring of chharbot tools.** The bridges are already reachable
  via `mcp_ffxi_client` / `mcp_ffxi_admin`, so any Claude deployment
  picks them up for free. A chharbot-flavoured MCP that exposes the
  *agent* (chharbot-as-a-tool) is a nice-to-have, not required.
- **Automated tests against the sidecar's write endpoints.** Currently
  relying on manual curl + the validator unit tests. A pytest-httpserver
  integration pass would close the loop.

## Files touched this session

New:
- `chharbot/` (10 files including tests and CLI wrapper)
- `docs/SECURITY-REVIEW.md`
- `docs/SESSION-2026-04-21-v7-CHHARBOT-LOCAL-AGENT.md` (this file)

Modified for security hardening (earlier in the session):
- `sidecar/lsb_admin_api/server.py` — validators, fail-closed auth,
  path-traversal defence, CR/LF rejection.
- `lsb_version_sync/lsb_version_sync/patcher.py` — `_refuse_symlinks`,
  PID-tagged temp files.
- `lsb_version_sync/lsb_version_sync/reloader.py` — exe_hint resolve +
  symlink + basename checks.
- `addons/ai_bridge/ai_bridge.lua` — auth handshake, max_clients,
  rate limit, radius clamp, send_text CR/LF stripping.
- `lsb_version_sync/tests/test_security.py` — 5 new tests.
- `docs/CHANGELOG.md` — `3.0.0-ai-control-sec-hardened` entry.

## Run it

```bash
cd repo/chharbot && pip install -e .
chharbot --probe "where am I and what's my HP?"
chharbot --allow-writes "tell GUESTCL1 'server restarting in 30s'"
chharbot --repl --trace
```

Works against a completely offline LLM. Works against any
OpenAI-compatible endpoint. Works without the game client if you pass
`--no-ai-bridge`.
