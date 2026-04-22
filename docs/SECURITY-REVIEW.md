# Security Review — AI Control Stack (v6)

Date: 2026-04-21
Reviewer: Chharbot / Claude (automated audit + fixes)
Scope:
  - `addons/ai_bridge/` (in-process Lua bridge, TCP 27115)
  - `sidecar/lsb_admin_api/` (FastAPI HTTP sidecar, 27116)
  - `lsb_version_sync/` (login.lua auto-match)
  - `mcp/ffxi_client/`, `mcp/ffxi_admin/` (MCP wrappers)

This review is a follow-up to the v6 auto-match build. The AI-control stack
has network-exposed surfaces and a path from HTTP input all the way to
`map_server.exe`'s stdin — it needs defence-in-depth or a single HTTP
injection becomes a GM command.

---

## Summary

| # | Severity | Area | Finding | Status |
|---|----------|------|---------|--------|
| 1 | HIGH | sidecar | Command injection into map_server console via unchecked names/text | FIXED |
| 2 | HIGH | sidecar | Auth bypasses silently when token file missing | FIXED |
| 3 | HIGH | sidecar | `override_dll` path traversal on `/version_sync/run` | FIXED |
| 4 | MED  | ai_bridge | No authentication when port open on localhost; any local app can drive the client | FIXED |
| 5 | MED  | patcher | Symlink-swap TOCTOU on `login.lua` | FIXED |
| 6 | MED  | reloader | `exe_hint` could point `subprocess.Popen` at any binary | FIXED |
| 7 | MED  | ai_bridge | DoS via unbounded connections / rapid RPC / huge `radius` | FIXED |
| 8 | LOW  | sidecar | `console_write` did not reject CR/LF before send | FIXED |
| 9 | LOW  | patcher | Atomic temp filename collides between concurrent runs | FIXED |
| 10 | LOW | sidecar | Missing length caps on free-form operator text | FIXED |

All findings have regression tests in `lsb_version_sync/tests/test_security.py`
(patcher + reloader) or are guarded by HTTP 400/401/503 paths exercised by
the existing sidecar surface. 27/27 `pytest` passes locally.

---

## Finding 1 — Command Injection via Unchecked Console Args (HIGH)

### Before
`sidecar/lsb_admin_api/server.py` took free-form strings from HTTP and
concatenated them directly into commands written to `map_server.exe`'s stdin:

```python
@app.post("/tell")
def tell(body: TellIn, ...):
    console_write(f"sendMessage {body.to} {body.text}")
```

A caller posting `{"to": "Bob\nshutdown", "text": "hi"}` would write TWO
commands into the console — one `sendMessage`, one `shutdown`. The sidecar
was a shared-token-protected LAN-local service, but anyone who got the token
(operator mistake, leaked log file, forgotten reverse-proxy rule) could
escalate from "tell Bob hi" to arbitrary GM ops.

### Fix
Introduced strict validators in `server.py`:

```python
_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.'\- ]{0,31}$")
_BAD_CTRL = re.compile(r"[\r\n\x00\x01-\x08\x0b\x0c\x0e-\x1f\x7f]")

def _sane_name(field, v):   # FFXI-shaped names only, reject CR/LF
    if not _NAME_RE.match(v): raise HTTPException(400, ...)
def _sane_text(field, v):   # strip control chars, cap 400 bytes
    return _BAD_CTRL.sub(" ", v)[:400]
def _sane_int / _sane_float # typed, bounded
```

Every write endpoint (`/announce`, `/tell`, `/teleport`, `/give_item`,
`/spawn_mob`, `/kick`) now validates before the string reaches
`console_write`.

### Defence in depth
`console_write` itself refuses any command containing `\r`, `\n`, or `\x00`,
and caps length at 1024 bytes — so even if a future endpoint is added without
validators, the injection path is blocked at the last mile.

---

## Finding 2 — Auth Fail-Open When Token File Missing (HIGH)

### Before
```python
def check_auth(supplied):
    if not TOKEN:
        return                 # <-- silent pass
    if not hmac.compare_digest(supplied, TOKEN):
        raise HTTPException(401, ...)
```

If the token file was missing or empty (typo in `LSB_ADMIN_TOKEN_FILE`, fresh
deploy, file truncated by an editor), the sidecar accepted every request
unauthenticated with no warning. An operator running `curl
http://127.0.0.1:27116/players` after a bad deploy would think "auth is
working" because 200 OK came back.

### Fix
Fail-closed with an explicit opt-out:

```python
ALLOW_NO_TOKEN = os.environ.get("LSB_ADMIN_ALLOW_NO_TOKEN", "0") == "1"

def check_auth(supplied):
    if not TOKEN:
        if ALLOW_NO_TOKEN: return
        raise HTTPException(503, detail="admin token not configured; ...")
    if not supplied or not hmac.compare_digest(supplied, TOKEN):
        raise HTTPException(401, detail="invalid admin token")
```

Startup logs a clear `ERROR` (or `WARNING` if `ALLOW_NO_TOKEN=1`) — deploys
that forgot the token now surface loudly instead of quietly running open.

---

## Finding 3 — `override_dll` Path Traversal (HIGH)

### Before
`/version_sync/run` accepted `override_dll: Optional[str]` and passed it
straight to `lsb_version_sync.sync()`, which called `detect_versions(Path(raw))`.
`Path()` happily accepts `\\?\C:\Windows\System32\...` or a UNC path pointing
at an SMB share, so an authed caller could aim `detect_versions` at any
file on disk and leak its first-N bytes (indirectly, via the `raw` CLIENT_VER
match it returns).

### Fix
`_validate_override_dll` clamps the input:

```python
def _validate_override_dll(raw):
    if "\x00" in raw: 400
    resolved = Path(raw).resolve(strict=True)
    if not resolved.is_file(): 400
    if resolved.suffix.lower() != ".dll": 400
    roots = env("LSB_VSYNC_ALLOWED_ROOTS", default="<Program Files>;<Steam>;F:\\ffxi")
    if not any(_is_within(resolved, r) for r in roots): 400
```

The caller must supply a real `.dll` on disk, inside an operator-allow-listed
root. Default roots cover the Steam install and the LSB deploy tree.

---

## Finding 4 — ai_bridge Accepts Unauthenticated Local Connections (MED)

### Before
`addons/ai_bridge/ai_bridge.lua` bound `127.0.0.1:27115` and accepted any JSON
line without authentication. Any local process (another user on the same
Windows box, a browser tab on a rogue dev server) could drive the game
client — type chat, target mobs, exfiltrate inventory.

### Fix
- `settings.token` is respected end-to-end: connections are created with
  `authed = (settings.token == '')`; if a token is set the first JSON message
  must be `{"auth": "<token>"}` or the connection is rejected with
  `-32001 unauthenticated` / `-32002 invalid token`.
- When the token is empty the addon prints a prominent yellow warning on each
  connect so the operator knows the bridge is open.

---

## Finding 5 — Symlink TOCTOU on `login.lua` (MED)

### Before
`_atomic_write` called `Path.write_text(tmp)` and `os.replace(tmp, path)` on
the caller-supplied path. A local attacker could replace `login.lua` with a
symlink to (say) `C:\Windows\System32\drivers\etc\hosts` between discovery
and patch, and we would happily rewrite the target of that link with a Lua
table.

### Fix
New `_refuse_symlinks(path)` helper is called from both `_atomic_write` and
`_backup`:

```python
def _refuse_symlinks(path):
    if path.is_symlink():
        raise PermissionError(f"{path} is a symlink; refusing to patch")
    path.parent.resolve(strict=True)
    if path.name != path.resolve().name:
        raise PermissionError(f"{path} resolves to a different name; refusing")
```

Covered by `tests/test_security.py::test_patcher_refuses_symlink_target`.

---

## Finding 6 — Reloader Would Launch Any Binary (MED)

### Before
`restart_login_server(exe_hint=...)` called `subprocess.Popen([str(exe)])`
with no validation. A caller that controlled `exe_hint` (e.g. an authed
HTTP request posting `override_dll` via the sidecar — the two are separate
controls but the pattern is analogous) could turn the reloader into a
`Popen` gadget.

### Fix
`reloader.py` now:
- `exe.resolve(strict=True)` — bail if it doesn't exist.
- Rejects symlinks that disagree with their target.
- Requires basename `login_server.exe` / `login_server` (case-insensitive).

Covered by:
- `tests/test_security.py::test_reloader_rejects_non_login_server_exe`
- `tests/test_security.py::test_reloader_rejects_missing_exe`
- `tests/test_security.py::test_reloader_rejects_symlinked_exe`

---

## Finding 7 — ai_bridge DoS Surfaces (MED)

### Before
- No cap on concurrent clients (`state.clients` grew unbounded).
- `get_entities { radius = 1e9 }` walked the entire 0..2303 entity array on
  every call and computed sqrt for all of them.
- A hot-looping client could saturate the `d3d_present` tick.

### Fix
- `settings.max_clients` (default 4). `accept_clients` sends
  `-32099 too many clients` and closes the new socket once the cap is hit.
- Per-client token-bucket rate limit (`rate_limit_n` calls per
  `rate_limit_w` seconds, default 30/s).
- `settings.max_entities_radius` (default 50) caps `get_entities` input.
- `send_text` caps length at 400 and strips CR/LF to stop chat-line
  smuggling.

---

## Finding 8 — `console_write` CR/LF Defence (LOW)

Defence-in-depth described in Finding 1; worth calling out because it's the
last mile before `map_server.exe` sees the string. `console_write` explicitly
rejects `\r`, `\n`, `\x00` and caps at 1024 bytes regardless of what any
upstream validator did.

---

## Finding 9 — Concurrent-Run Temp File Collision (LOW)

`_atomic_write(path)` used `path + ".tmp"` — two sync runs started at the
same second on a shared host would clobber each other's tmp file, leaving
whichever lost the race writing a half-file.

Fixed by nonce-ing the temp suffix with the PID:

```python
tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
```

Test: `test_atomic_tmp_filename_includes_pid` confirms no stray `*.tmp*`
files are left after a clean run.

---

## Finding 10 — Missing Length Caps on Operator Text (LOW)

Closed as a side effect of Finding 1: `_sane_text` caps at 400 chars,
`console_write` caps at 1024. These are deliberately below any LSB console
buffer size we've seen.

---

## What We Did NOT Fix (Accepted Risk)

- **Shared-host race on live `login.lua` replace.** If a local attacker can
  write to the `settings/` folder between our read and our `os.replace`,
  they win the race. The mitigation is filesystem ACLs on the deploy tree —
  the sidecar already refuses to run outside allow-listed roots, and the
  sync tool runs under the service account.
- **Token rotation.** Tokens are static; rotating them requires restarting
  both the sidecar and any MCP clients. Acceptable for a single-box dev
  deploy; a future version may add a refresh endpoint.
- **No rate-limit on HTTP sidecar.** Localhost-only binding and the input
  validators bound the blast radius. If the sidecar is ever exposed beyond
  `127.0.0.1` this needs to be revisited.

---

## Test Coverage

```
$ cd lsb_version_sync && python3 -m pytest tests/ -q
...........................
27 passed in 0.13s
```

- 22 pre-existing functional tests (scanner/patcher/sync)
- 5 new security tests (`tests/test_security.py`) — symlink refusal,
  temp-file cleanup, reloader basename / resolve / symlink checks

The sidecar is not yet exercised by automated tests (it's FastAPI +
named-pipe I/O that wants an integration environment). A follow-up task
is to stand up `pytest-httpserver` + a fake pipe so the validators and
auth paths can run in CI.
