# Session 2026-04-21 v6 — retail CLIENT_VER auto-match (`lsb_version_sync`)

Closes the last open loop of the FFXI-3331 thread. v5 gave us the
one-shot `patch-ver-lock.ps1` for disabling the version lock; v6
replaces the "disable the check" posture with an actual solution: the
server tracks retail automatically and the lock stays on.

## The community gap this fills

Every other LSB-derived private server we surveyed handles a retail
patch the same way: a human reads the new version string out of the
client (or their packet dump), edits `settings/login.lua`, commits it,
and tells their players to reconnect. LSB mainline has no code for
this — its `VER_LOCK = 2` (greater-or-equal) comparator still requires
the config string to at least be in the ballpark of retail, and
retail's format uses trailing revisions that break lex comparison.

`lsb_version_sync` is the first auto-match implementation we're aware
of. It reads `FFXiMain.dll` directly, extracts every plausible
`YYYYMMDD_R` candidate, picks the newest, writes it into `login.lua`
atomically, and bounces `login_server`. Combined with a Windows
Scheduled Task it runs at boot + every 6 hours, so a SE patch lands →
`FFXiMain.dll` gets a new date-stamp → the next run detects the
change → `login.lua` updates → `login_server` restarts → next login
works. Totally unattended.

## What shipped

```
lsb_version_sync/
    lsb_version_sync/
        __init__.py        public API
        scanner.py         regex-over-bytes, both ASCII and UTF-16LE
        patcher.py         atomic login.lua rewrite w/ timestamped backup
        reloader.py        login_server bounce (psutil if present, tasklist fallback)
        sync.py            orchestrator with monotonicity guard
        hooks.py           pre-startup hook + scheduled-task entry point
        config.py          env-driven
        __main__.py        CLI (status / detect / sync / scheduled)
    tests/
        test_scanner.py    9 unit tests
        test_patcher.py    7 unit tests
        test_sync.py       6 integration tests
    bin/
        lsb-version-sync.ps1            PowerShell wrapper
        register-scheduled-task.ps1     Task Scheduler registrar
    pyproject.toml                      pip-installable as `lsb-version-sync`
    README.md
```

All 22 tests pass in <0.1 s on stdlib-only fixtures. The package has
zero required third-party dependencies; `psutil` is used when present
for faster/cleaner process enumeration but the code falls back to
Windows `tasklist` parsing when psutil isn't available.

## Integration points added

- `sidecar/lsb_admin_api/server.py` got two new endpoints:
  - `GET /version_sync/status` — current vs. detected, `in_sync`, `drift`
  - `POST /version_sync/run` — full sync (supports `dry_run`, `force`,
    `override_dll`, `restart`)
- `mcp/ffxi_admin/server.py` got two new MCP tools:
  - `version_sync_status()`
  - `version_sync_run(dry_run=False, force=False, override_dll=None, restart=True)`

So from Claude, in a fresh chat:

```
>>> ffxi_admin.version_sync_status
{configured_client_ver: "30260203_0", detected_client_ver: "30260413_2",
 in_sync: false, drift: true, ...}

>>> ffxi_admin.version_sync_run
{ok: true, previous_client_ver: "30260203_0", new_client_ver: "30260413_2",
 restart: {started_pid: 12345}, message: "patched CLIENT_VER ..."}
```

That's the full fix path as two tool calls — no RDP, no file editing,
no service manager clicks.

## Design choices worth calling out

- **Regex-over-bytes, not PE parsing.** We considered parsing the PE
  resource table for a `VS_VERSION_INFO` record, but FFXI's build
  version string isn't stored there. A forward-scan over the mmap'd
  bytes with a tight plausibility allow-list is both simpler and more
  resilient if SE moves the string around.
- **Two encodings.** ASCII covers the string-table usage; UTF-16LE
  covers the resource section and any `.rsrc` strings. Both are tested.
- **Monotonicity guard by default.** A stale FFXiMain.dll (e.g. a
  backed-up install on a different drive) should never regress a
  correctly-configured live server. The guard can be overridden with
  `--force` or `force=true`.
- **Only login_server is bounced.** CLIENT_VER is read only by
  login_server on startup; map_server doesn't care. Keeping the map
  process up means active players aren't kicked when the sync runs.
- **Backups every write.** `login.lua.ver-sync-bak.<timestamp>` sits
  alongside the original, so any rollback is a simple `Copy-Item`.

## Task list after v6

- #7 "Resolve FFXI-3331 client/server version mismatch" — solution in
  place via `lsb_version_sync`; a live-box run closes it out.
- #12 "Build lsb_version_sync retail auto-match subsystem" — **complete.**

## Files added/updated

| File | Purpose |
|---|---|
| `lsb_version_sync/` | Whole new Python package (see tree above) |
| `sidecar/lsb_admin_api/server.py` | Adds `/version_sync/status` + `/version_sync/run` |
| `mcp/ffxi_admin/server.py` | Adds `version_sync_status` + `version_sync_run` MCP tools |
| `README.md` | New top-level README tying subsystems together |
| `docs/SESSION-2026-04-21-v6-VERSION-AUTO-MATCH.md` | This document |
