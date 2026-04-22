# chharbot — local-model FFXI agent

`chharbot/` is the third leg of the v5+v6 AI-control stack. Where
`addons/ai_bridge/` exposes the game client and `sidecar/lsb_admin_api/`
exposes the server, `chharbot/` is the *brain*: a local-LLM agent that
reads both bridges, decides what to do, and — with explicit opt-in —
acts on the world.

No framework. No Claude in the loop. No cloud calls required.

```
               ┌──────────────────────────────────────────┐
               │        chharbot (this package)           │
               │   ┌────────────────────────────────┐     │
               │   │  agent loop (ReAct, ~80 lines) │     │
               │   └────────────┬───────────────────┘     │
               │                │                         │
               │   ┌────────────▼──────────┐              │
               │   │  tool dispatcher      │              │
               │   │  (JSON-schema valid.) │              │
               │   └───┬──────────────┬────┘              │
               └───────┼──────────────┼────────────────────┘
                       │              │
                       ▼              ▼
             TCP 27115 ai_bridge    HTTP 27116 lsb_admin_api
             (in-game state)        (DB + console)
                       │              │
                       ▼              ▼
                   Ashita/FFXI   map_server.exe / LSB DB
```

The LLM is pluggable: Ollama by default (local llama3.1 / qwen2.5 / etc.)
or any OpenAI-compatible chat-completions endpoint (llama.cpp server, LM
Studio, vLLM, OpenAI itself).

---

## Install

```bash
cd repo/chharbot
pip install -e .
```

Dependencies: Python 3.10+, no third-party packages at runtime. `pytest`
for the test suite.

---

## Configure

Two shared secrets live on the LSB box. Chharbot reads them from files:

| Token                 | File (default)                            | Consumer                          |
|-----------------------|-------------------------------------------|-----------------------------------|
| admin sidecar         | `F:\ffxi\deploy\.lsb_admin_token`         | `lsb_admin_api` HTTP `X-Admin-Token` |
| ai_bridge handshake   | `F:\ffxi\deploy\.aibridge_token`          | `ai_bridge` JSON `{"auth":"…"}`  |

Either file can be missing if the corresponding bridge has no token
configured — chharbot will run without auth in that mode.

Environment fallbacks: `LSB_ADMIN_TOKEN`, `LSB_AIBRIDGE_TOKEN`,
`OPENAI_API_KEY`.

---

## Usage

### One-shot

```bash
# Ollama, read-only (default)
chharbot "how many characters are in the database right now?"

# OpenAI-compatible endpoint
chharbot --backend openai --llm-url http://127.0.0.1:8080/v1 \
  --model llama-3.1-8b-instruct \
  "what's my HP and where am I?"
```

### Writes

`--allow-writes` exposes five extra tools: `client_send_text`,
`client_target`, `server_announce`, `server_tell`, `version_sync_run`.

```bash
chharbot --allow-writes --trace \
  "tell GUESTCL1 that maintenance starts in 5 minutes, then announce the same"
```

### Interactive REPL

```bash
chharbot --repl
>>> what's my current zone?
>>> list the last 10 lines of the map_server log
>>> ^D
```

### Server-only mode

If ai_bridge isn't reachable (game client not running), skip it:

```bash
chharbot --no-ai-bridge "version_sync status?"
```

Or probe at startup and drop it automatically:

```bash
chharbot --probe "are we in sync?"
```

---

## Tool catalogue

Read-only (always available):

| Tool                    | What it returns                                           |
|-------------------------|-----------------------------------------------------------|
| `client_get_state`      | Player HP/MP/TP, jobs, position, target                   |
| `client_get_chat_tail`  | Last N chat lines                                         |
| `client_get_entities`   | Nearby entities within radius (capped at 50 yalms)        |
| `client_get_inventory`  | Bags + items (id, name, count)                            |
| `client_ping`           | Round-trip check                                          |
| `server_health`         | Sidecar probe                                             |
| `server_stats`          | chars / accounts totals                                   |
| `server_list_players`   | Every char row                                            |
| `server_get_player`     | Char by id                                                |
| `server_zones`          | Zone populations                                          |
| `server_event_tail`     | map_server log tail                                       |
| `version_sync_status`   | login.lua vs retail drift                                 |

Writes (require `--allow-writes`):

| Tool                | Action                                          |
|---------------------|-------------------------------------------------|
| `client_send_text`  | Type into the FFXI chat input                   |
| `client_target`     | Target an entity by server id                   |
| `server_announce`   | Broadcast to all players                        |
| `server_tell`       | Whisper one player                              |
| `version_sync_run`  | Run login.lua auto-match (dry-run by default)   |

Every tool argument is validated against a JSON-schema before it reaches
the bridge. A malformed call returns `{"error": ...}` back to the model
rather than crashing — the model can read the error and try again.

---

## Tests

```bash
cd repo/chharbot
PYTHONPATH=. python3 -m pytest tests/ -q
```

24 tests, all offline (no sockets or HTTP to anything outside of the
process). Coverage: tool registry shape (read-only vs writes), dispatch
validation (unknown args, bad JSON, missing required args, BridgeError
capture), agent loop (single-tool, multi-tool chain, unknown-tool
surfaced to model, max_steps guard, system prompt injection), bridge
transports (TCP round-trip with/without handshake, HTTP reads + writes
+ error surfaces).

---

## Safety notes

- Chharbot is read-only by default. Writes require an explicit CLI flag.
- The admin sidecar is hardened per `docs/SECURITY-REVIEW.md` (input
  validators, CR/LF rejection at `console_write`, path-traversal guards
  on `override_dll`, fail-closed auth).
- The ai_bridge handshake is enforced when a token is configured on the
  Ashita side; chharbot supplies it on connect.
- Bridges bind localhost only. Nothing in this package opens a listener
  of its own.
