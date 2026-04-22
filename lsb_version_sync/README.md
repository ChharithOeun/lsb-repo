# lsb_version_sync

Auto-match the retail FFXI `CLIENT_VER` string into LandSandBoat's
`login.lua` so you never get FFXI-3331 ("The game's data has been
updated") again.

## Why this exists

LSB ships a hardcoded `CLIENT_VER` in `settings/login.lua`. When Square
Enix patches retail, that string drifts and every connecting client
trips `login_version_lock`. Community practice is to either (a) edit
`login.lua` by hand after each retail patch, or (b) turn the check off
with `VER_LOCK = 0`.

`lsb_version_sync` is option (c): read the retail client's current
version directly out of `FFXiMain.dll`, diff it against
`login.lua.CLIENT_VER`, rewrite the file if it drifted, and bounce
`login_server`. Run as a scheduled task every few hours and your
private server tracks retail automatically.

## Layout

```
lsb_version_sync/
    __init__.py        public API: sync(), detect_versions(), ...
    scanner.py         pulls CLIENT_VER candidates out of FFXiMain.dll
    patcher.py         rewrites login.lua atomically with a backup
    reloader.py        bounces login_server.exe
    sync.py            high-level orchestrator (with monotonicity guard)
    hooks.py           pre-startup hook + scheduled-task entry point
    config.py          env-driven configuration
    __main__.py        CLI (python -m lsb_version_sync ...)
bin/
    lsb-version-sync.ps1            PowerShell wrapper
    register-scheduled-task.ps1     one-shot Task Scheduler registration
tests/
    test_scanner.py                 21 pytests; all pass on stdlib-only
    test_patcher.py
    test_sync.py
pyproject.toml                      installable with `pip install -e .`
```

## Quick start

```powershell
# 1. Install.
pip install -e F:\ffxi\deploy\lsb_version_sync

# 2. See what's going on.
lsb-version-sync status

# 3. Dry-run (no writes).
lsb-version-sync sync --dry-run

# 4. Actually sync (patches login.lua, bounces login_server).
lsb-version-sync sync

# 5. Turn it into a scheduled task (boot + every 6 hours).
powershell -NoProfile -ExecutionPolicy Bypass `
  -File F:\ffxi\deploy\lsb_version_sync\bin\register-scheduled-task.ps1
```

## How detection works

`scanner.py` memory-maps `FFXiMain.dll` and runs two regexes over the
raw bytes:

- ASCII: `(?<![0-9_])([0-9]{8})_([0-9]{1,2})(?![0-9_])`
- UTF-16LE: same shape interleaved with null bytes.

Any hit is validated against a plausibility allow-list (decade in
`{20xx, 30xx}`, month 1-12, day 1-31, year 2002-2039). The newest
surviving candidate (lex-largest date) wins.

This is deliberately tolerant. If SE ever changes the wire format we
update the regex in one place; no pickled offsets, no memory addresses
to re-dump every patch.

## Safety guards

- **Atomic write with backup.** Every `login.lua` rewrite goes through
  a temp file + `os.replace`, and a timestamped backup
  (`login.lua.ver-sync-bak.YYYYMMDD-HHMMSS`) is dropped next to the
  original before any change.
- **Monotonicity guard.** By default the sync only rewrites if the
  detected version is strictly newer than what's configured. This
  stops a stale DLL (e.g. a backup install) from downgrading a
  correctly-configured live server. Pass `--force` to override.
- **VER_LOCK preserved.** The sync touches `CLIENT_VER` only; your
  `VER_LOCK` policy (0 / 1 / 2) is whatever you configured. Set
  `LSB_VSYNC_KEEP_VER_LOCK=0` to let the sync manage it too.
- **Only login_server is bounced.** `map_server.exe` stays up; players
  in-game during a resync are not kicked.

## Integration points

- **HTTP sidecar** (`sidecar/lsb_admin_api`): exposes
  `GET /version_sync/status` and `POST /version_sync/run`, gated by the
  admin token. The MCP forwards calls to these.
- **MCP tool** (`mcp/ffxi_admin`): Claude / Chharbot can call
  `ffxi_admin.version_sync_status` and `ffxi_admin.version_sync_run`
  directly — no screenshots, no clicks.
- **Scheduled task**: `bin/register-scheduled-task.ps1` registers a
  SYSTEM-level task that runs at boot and every 6 hours, writing
  outcome JSON into `F:\ffxi\deploy\lsb-version-sync.log`.
- **Pre-startup hook**: `from lsb_version_sync.hooks import
  pre_login_start_hook; pre_login_start_hook()` — call from any
  custom login_server launcher before the exe is started so the
  config is already correct on the first auth.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `LSB_LOGIN_LUA` | `F:\ffxi\server\settings\login.lua` | Config to patch |
| `LSB_LOGIN_EXE` | (discovered from running proc) | login_server.exe path |
| `LSB_VSYNC_DLL` | (candidate list in `config.py`) | `;`-separated FFXiMain.dll search paths |
| `LSB_VSYNC_LOG` | `F:\ffxi\deploy\lsb-version-sync.log` | JSON outcome log |
| `LSB_VSYNC_KEEP_VER_LOCK` | `1` | `0` = sync also manages VER_LOCK |
| `LSB_VSYNC_DEFAULT_VER_LOCK` | `2` | Applied when `KEEP_VER_LOCK=0` |
| `LSB_VSYNC_MONOTONIC` | `1` | `0` = skip the "newer than configured" guard |

## Running the tests

```bash
cd lsb_version_sync
pip install pytest
pytest tests/ -q
```

22 tests, stdlib-only fixtures, runs in <1 second.

## License

MIT. Published as part of the Chharbot FFXI AI-control bundle.
