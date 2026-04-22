# Postmortem — "Incorrect PlayOnline ID or password"

**Date:** 2026-04-20
**Impact:** Nobody could log into the local LSB server with `GUESTCL1` / `guestpass`, including via the intended Guest Login path.
**Status:** Resolved end-to-end at the xiloader layer. Ashita integration still needs the addon change described in `ASHITA-INTEGRATION.md`.

## Timeline

1. User reports `Incorrect PlayOnline ID or password` when clicking Guest Login in POL Viewer.
2. Initial hypothesis: bad password hash in DB. Confirmed — `accounts.password` for ids 1000 and 1001 did not match either BCrypt or MariaDB `PASSWORD()` output for `guestpass`.
3. Re-hashed via `fix-password.ps1`. Verified `pw_head='*61E'`, `pw_len=41`, matches LSB's legacy fallback branch in `validatePassword()`.
4. Retested via POL Viewer — same error.
5. Second hypothesis: POL Viewer itself cannot speak LSB's protocol. Confirmed — POL Viewer routes to SE's defunct auth infrastructure; the Guest Login button can never reach our `xi_connect`. This is architectural, not a bug.
6. Switched to Ashita's Altana (Private Server) profile. Play button threw `Failed to install Ashita! Error: 0`.
7. Inspected `Private Server.xml`. `boot_file` pointed at Steam's `polboot.exe`, a thin bootstrapper. Re-pointed at `ffxi-bootmod\pol.exe`. Play button threw the same error.
8. Third hypothesis: xiloader too old. Confirmed — bundled xiloader was 1.0.0.4; LSB requires `2.1.x` (hard-coded in `auth_session.h`).
9. Swapped in xiloader 2.1.1 (backup saved). Launched directly from cmd with credentials as CLI args. Got `Successfully logged in as GUESTCL1!` and `Connected to server!`.
10. Attempted Ashita Altana again — still fails, but for a new reason: xiloader is not an injectable target. Ashita needs an addon that handles xiloader internally (see `ASHITA-INTEGRATION.md`).

## Root causes (three independent bugs)

1. **Stale password hash.** `accounts.password` for guest rows was in a format `validatePassword()` didn't accept.
2. **Stale xiloader.** `ffxi-bootmod\pol.exe` was 1.0.0.4, below the hard-coded `SupportedXiloaderVersion = {2,1,0}` floor.
3. **Stale boot_file pointer.** Ashita's profile pointed at SE's `polboot.exe` instead of the LSB-aware xiloader.

Any one of these alone would have prevented login. All three had to be fixed.

## Why POL Viewer is a dead end

PlayOnline Viewer (`POL.exe`) is SE's retail launcher. Its "Guest Login" button routes through SE's defunct `playonline.com` auth servers. There is no LSB protocol translation in POL Viewer. The only private-server-aware clients are:
- xiloader (standalone, command-line)
- Ashita v4 (via the xiloader-fixed or equivalent addon)
- Windower 4 (with its bundled xiloader)

Users should not be directed to POL Viewer for login. The control panel's Guest Login button must bypass POL entirely.

## What changed

| Change | File | Before | After |
|---|---|---|---|
| Password hash | `xidb.accounts` rows 1000, 1001 | Legacy/unknown | `PASSWORD('guestpass')` = `*61E5B73...` |
| xiloader binary | `Ashita\ffxi-bootmod\pol.exe` | 1.0.0.4 (47,616 B) | 2.1.1 (1,072,128 B, MD5 `44FE…`) |
| Ashita profile | `Ashita\config\boot\Private Server.xml` | `polboot.exe` | `ffxi-bootmod\pol.exe` |

## Artifacts

- `F:\ffxi\server\fix-password.ps1` — re-hashes guest passwords safely
- `F:\ffxi\server\xiloader-upgrade.log` — step-by-step ledger of the binary swap
- `F:\ffxi\Ashita\ffxi-bootmod\pol.exe.v1.0.0.4.bak` — original xiloader, preserved for rollback
- `docs/CHANGELOG.md` — release notes
- `docs/ASHITA-INTEGRATION.md` — remaining Ashita addon work
- `docs/WINDOWER-INTEGRATION.md` — same upgrade, Windower path

## Lessons learned

- **Hard-coded version constants in the server are a landmine for new clients.** `SupportedXiloaderVersion` probably needs to be a config value so ops can relax or tighten it without a rebuild.
- **The legacy PASSWORD() fallback is load-bearing for old account rows.** BCrypt migration hasn't happened yet; anything that re-hashes accounts must use `PASSWORD()` to match the fallback branch until BCrypt is rolled out.
- **POL Viewer must be removed from the guest-login happy path.** Users clicking "Guest Login" expect to be logged in; they should not be routed through SE's dead auth infrastructure.
- **Ashita's `boot_file` must point at an injectable target, not at xiloader.** The boot_file assumption ("whatever this runs is what I'll inject into") breaks when the boot binary is a short-lived auth helper that spawns the real client.

## Follow-ups (tracked separately)

- [ ] Install `xiloader_fixed` (or equivalent) Ashita addon; re-point `boot_file` at retail `pol.exe`
- [ ] Verify character-select screen renders after auth
- [ ] Apply xiloader 2.1.1 to Windower 4 per `WINDOWER-INTEGRATION.md`
- [ ] Consider making `SupportedXiloaderVersion` a server config value
- [ ] Remove POL Viewer from any guest-login documentation and from the control panel's "Launch" path
