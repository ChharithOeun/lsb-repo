# LSB Auth Fix — 2026-04-20 Session Bundle

This folder contains the documentation and scripts produced during the 2026-04-20 session that worked on the `Incorrect PlayOnline ID or password` failure for the Chharbot FFXI / LandSandBoat deployment.

## IMPORTANT — READ FIRST

The original claims in `CHANGELOG.md` about xiloader 2.1.1 being deployed were verified
incorrect in the evening re-inspection. **The pol.exe binary on disk is still the 47 KB
Ashita Bootloader (2014-2017), not xiloader 2.1.1.** Character select is therefore not yet
reachable. See `SESSION-2026-04-20-v2-STATUS.md` for the full corrected analysis.

**Update 2026-04-20 (v3) — DONE:** The real xiloader 2.1.1 binary has been pulled,
verified (MD5 `44FE5F23BF76E4E847946B5B76F1E061`, 1,072,128 bytes), installed at
`F:\ffxi\Ashita\ffxi-bootmod\pol.exe` on the live Windows box, and smoke-tested with
GUESTCL1/guestpass against LSB. xiloader printed `LandSandBoat Boot Loader ... (v2.1.1)`
and `Successfully logged in as GUESTCL1!` — full handshake verified. The original
47 KB Ashita Bootloader is preserved as `pol.exe.bootloader.bak`. See
`docs/SESSION-2026-04-20-v3-RESOLUTION.md` for the complete verification log.

**Update 2026-04-21 (v6) — RETAIL VERSION AUTO-MATCH:**
`lsb_version_sync/` is a stdlib-only Python package that reads the current
retail `CLIENT_VER` directly out of `FFXiMain.dll`, diffs it against
`login.lua`, rewrites the config atomically with a timestamped backup,
and bounces `login_server`. 22 unit tests pass in <0.1 s. A bundled
PowerShell task registrar (`lsb_version_sync/bin/register-scheduled-task.ps1`)
turns it into a boot + every-6-hours Windows Scheduled Task, so a retail
patch from SE is picked up automatically — no operator intervention per
SE patch, ever again. The sidecar exposes `/version_sync/status` and
`/version_sync/run` endpoints, and `mcp_ffxi_admin` gets
`version_sync_status` + `version_sync_run` MCP tools so Claude can drive
the whole thing. Full writeup in
`docs/SESSION-2026-04-21-v6-VERSION-AUTO-MATCH.md`.

**Update 2026-04-21 (v5) — FFXI-3331 FIX + AI CONTROL SUBSYSTEM:**
`examples/patch-ver-lock.ps1` disables LSB's strict `VER_LOCK` (or sets a
specific `CLIENT_VER`) and bounces `login_server` so the retail client
can get past the FFXI-3331 version-mismatch dialog. In parallel, the two
AI-control bridges designed in `docs/AI-CONTROL-ARCHITECTURE.md` are now
implemented: Ashita `ai_bridge` addon (client-side JSON-RPC on
`127.0.0.1:27115`) and `sidecar/lsb_admin_api` (server-side HTTP on
`127.0.0.1:27116`), each wrapped by a FastMCP server under `mcp/`.
`examples/deploy-ai-control.ps1` pushes the whole thing to the live box
in one shot. Full writeup in
`docs/SESSION-2026-04-21-v5-AI-CONTROL-AND-VER-LOCK.md`.

**Update 2026-04-21 (v4) — RETAIL CHAIN VERIFIED:** `examples/finish5.ps1`
stages xiloader 2.1.1 next to `FFXiMain.dll` in the Steam retail install
(`C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI`),
launches it with CWD = that game dir, and captures full stdout. Result:
xiloader auths (`Successfully logged in as GUESTCL1!`), applies the hairpin
fix, chain-loads `FFXiMain.dll`, and the retail client draws its window
(title `FINAL FANTASY XI`). The game gets as far as the version-check
dialog and displays `Error code: FFXI-3331 — The game's data has been
updated`. That is the LSB `login_version_lock` / `CLIENT_VER` mismatch,
not a loader-chain bug — tracked as task #7. See
`docs/SESSION-2026-04-21-v4-RETAIL-CHAIN-VERIFIED.md` for the full trace.

## What works now

`GUESTCL1` / `guestpass` authenticates end-to-end against the local LSB server when xiloader 2.1.1 is launched directly:

```
F:\ffxi\Ashita\ffxi-bootmod\pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin --hide
```

Output ends with `Successfully logged in as GUESTCL1!` and `Connected to server!`.

## What still needs work

- **Retail FFXI Steam client IS installed** at `C:\Program Files (x86)\Steam\steamapps\common`
  (user-confirmed; Windower 4 launches retail from there successfully). v5's
  "not installed" conclusion was based on an overly narrow candidate list.
  v6's `examples/smoke-test-altana.ps1` discovers the real path via four
  strategies (expanded candidate list, Steam-common folder scan, Windower
  `settings.xml` parse, `where.exe /R` fallback), auto-patches the
  `Private Server.xml` `boot_file`, and launches Ashita. Re-run it on the
  live box to close out the Altana chain:
  `powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\smoke-test-altana.ps1`.
  Use `examples/find-retail-pol.ps1` first for a read-only dry run if you
  want to eyeball the candidates.
- Ashita v3 Altana profile — `xiloader_fixed` addon is built AND deployed to
  `F:\ffxi\Ashita\addons\xiloader_fixed` (see `ASHITA-INTEGRATION.md`); will
  activate once retail client is installed.
- Windower 4 — same xiloader upgrade, different path (see `WINDOWER-INTEGRATION.md`)
- POL Viewer — nothing to do. POL cannot speak LSB's protocol; it must be removed from the guest-login path entirely.

## Files in this bundle

| File | Purpose |
|---|---|
| `CHANGELOG.md` | Release notes for the 2.1.1-auth-fix version |
| `AUTH-FIX-POSTMORTEM.md` | Full root-cause analysis, timeline, lessons learned |
| `ASHITA-INTEGRATION.md` | What's left to do on the Ashita side |
| `WINDOWER-INTEGRATION.md` | Same xiloader upgrade for Windower |
| `IDEAS-POL-ONE.md` | Future POL-one ideas (character UI past the 4-slot limit, etc.) |
| `DEPLOY.md` | One-page deploy guide — read this to run the fix |
| `../examples/run-all-fixes.ps1` | Master orchestrator — runs all three scripts with summary |
| `../examples/run-all-fixes.bat` | Double-click launcher for the orchestrator |
| `../examples/install-xiloader-2.1.1.ps1` | **v3** Downloads xiloader 2.1.1, verifies MD5, backs up old pol.exe, installs, smoke tests |
| `../examples/install-xiloader-2.1.1-offline.ps1` | **v3** Same install flow but from a pre-staged binary (no network) |
| `../examples/install-ashita-xiloader-addon.ps1` | **NEW** Installs xiloader_fixed addon from repo, re-points profile at retail pol.exe |
| `../examples/deploy-xiloader-fixed-addon.ps1` | **v5** Self-contained one-shot deploy (no repo checkout required; writes addon + boot profile inline) |
| `../examples/smoke-test-altana.ps1` | **v6** End-to-end smoke test with 4-strategy retail pol.exe discovery (candidate list / Steam-common scan / Windower settings parse / `where.exe /R` fallback), auto-patches `Private Server.xml` `boot_file`, launches Ashita, tails latest Ashita log, writes to `F:\ffxi\deploy\altana-smoke-test.log` |
| `../examples/find-retail-pol.ps1` | **v6** Read-only diagnostic: runs the same 4 strategies and prints a unique size/version/source-annotated table of every pol.exe candidate (excludes the LSB xiloader). Logs to `F:\ffxi\deploy\find-retail-pol.log` |
| `../examples/Launch-Altana.bat` | **NEW** One-click wrapper: xiloader → Ashita Altana profile |
| `../examples/Launch-Altana.ps1` | **NEW** PowerShell sibling of Launch-Altana.bat with PID-diff logging |
| `../addons/xiloader_fixed/xiloader_fixed.lua` | **NEW** Ashita v3 addon source (autoloads xiloader on `load`) |
| `../addons/xiloader_fixed/README.md` | **NEW** Addon usage, commands, troubleshooting |
| `../addons/xiloader_fixed/settings/settings.lua` | **NEW** Default settings file (server/user/pass/hairpin/etc.) |
| `../examples/upgrade-windower-xiloader.ps1` | Runnable script for the Windower upgrade |
| `../examples/verify-guest-login.ps1` | Runnable smoke test across all three layers |
| `../config/Private Server.xml.reference` | Current state of the Ashita profile |
| `../binaries/xiloader-2.1.1.exe` | **v3** The verified xiloader 2.1.1 binary (1,072,128 B, MD5 `44FE5F23BF76E4E847946B5B76F1E061`) |
| `SESSION-2026-04-20-v3-RESOLUTION.md` | 2026-04-20 session verification log + install paths |
| `../examples/finish5.ps1` | **v4** Canonical end-to-end retail smoke test. Stages xiloader next to `FFXiMain.dll`, launches with CWD = retail game dir, captures xiloader stdout/stderr, polls for 30 s. Proves the client→xiloader→FFXiMain chain. |
| `../examples/diag-final.ps1` | **v4** Post-run state snapshot: process list, FFXiMain.dll module scan, LSB netstat. |
| `SESSION-2026-04-21-v4-RETAIL-CHAIN-VERIFIED.md` | **v4** End-to-end retail chain verification — from xiloader stdout all the way to the FFXI window on screen (stopped at FFXI-3331 version lock) |
| `../examples/patch-ver-lock.ps1` | **v5** Patches `login.lua` (backup first), optionally rewrites `CLIENT_VER`, sets `VER_LOCK=0`, restarts `login_server` |
| `../examples/deploy-ai-control.ps1` | **v5** One-shot deploy for the whole AI-control subsystem (addon + MCPs + sidecar + shared token) |
| `../addons/ai_bridge/` | **v5** Ashita v3 addon: localhost JSON-RPC bridge for client state/actions |
| `../sidecar/lsb_admin_api/` | **v5** HTTP sidecar next to `map_server.exe`: DB reads + GM console writes via named pipe |
| `../mcp/ffxi_client/` | **v5** FastMCP wrapper exposing `ai_bridge` as MCP tools |
| `../mcp/ffxi_admin/` | **v5** FastMCP wrapper exposing `lsb_admin_api` as MCP tools |
| `../mcp/mcp.example.json` | **v5** Drop-in MCP registration for Claude |
| `AI-CONTROL-ARCHITECTURE.md` | **v5** Design doc for the two-bridge/two-MCP approach |
| `SESSION-2026-04-21-v5-AI-CONTROL-AND-VER-LOCK.md` | **v5** Full session writeup for the FFXI-3331 fix + AI control subsystem |
| `../lsb_version_sync/` | **v6** Auto-match retail CLIENT_VER into LSB login.lua (package + tests + scheduled task) |
| `SESSION-2026-04-21-v6-VERSION-AUTO-MATCH.md` | **v6** Full session writeup for the version auto-match subsystem |

## The three bugs, in one paragraph

Guest login was broken by three independent failures stacked on top of each other: the `accounts.password` hash for the guest rows was in a format LSB's `validatePassword()` didn't accept; the bundled xiloader (1.0.0.4) was below LSB's hard-coded `SupportedXiloaderVersion = {2,1,0}` floor; and Ashita's Private Server profile `boot_file` pointed at SE's thin `polboot.exe` rather than the xiloader. All three are fixed.

## The fix, in one paragraph

Re-hashed the guest passwords via `UPDATE accounts SET password = PASSWORD('guestpass')`, swapped the xiloader binary for 2.1.1 (MD5 `44FE5F23BF76E4E847946B5B76F1E061`) with a versioned backup, and re-pointed Ashita's `boot_file` at the upgraded xiloader. After that, xiloader authenticates cleanly and the server reports a connected session.

## Don't do these

- Don't tell users to click POL Viewer's Guest Login. POL's auth cannot reach LSB.
- Don't put the DB password in shell history. Use `mariadb.exe --defaults-extra-file=<path>` instead.
- Don't point Ashita's `boot_file` at xiloader and then expect Ashita's injector to work. It won't — xiloader isn't an injectable target.
