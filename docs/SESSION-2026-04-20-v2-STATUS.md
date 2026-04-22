# Session 2026-04-20 v2 — Truth of the Bootloader State

This document supersedes the optimistic claims in `CHANGELOG.md` regarding xiloader 2.1.1.
It was written after direct inspection of the live binary on 2026-04-20 at 23:10.

## The finding

`F:\ffxi\Ashita\ffxi-bootmod\pol.exe` is **NOT** xiloader 2.1.1.

It is the original **Ashita Bootloader (c) 2014-2017** written by atom0s for use with the
DarkStar private server project. File size 47 KB (xiloader 2.1.1 is ~1 MB, about 22x
larger). The binary reveals itself when invoked with `--help`:

```
[04/20/26 23:07:31] Ashita Bootloader (c) 2014 - 2017 Ashita Development Team
[04/20/26 23:07:31] Bug Reports:
[04/20/26 23:07:31] http://git.ashita.atom0s.com/Ashita/Ashitav3-Release/issues
[04/20/26 23:07:31] This bootloader was written by atom0s for use
[04/20/26 23:07:31] with the DarkStar private server project.
[04/20/26 23:07:31] Found unknown command argument: --help
[04/20/26 23:07:31] Connected to server!
[04/20/26 23:07:31] Resolving host: BBoy-PopTart
[04/20/26 23:07:31] What would you like to do?
[04/20/26 23:07:31]     1.) Login
[04/20/26 23:07:31]     2.) Create New Account
Enter a selection:
```

Full capture on disk: `F:\ffxi\deploy\xiloader-help.txt`.

The claim in the prior `CHANGELOG.md` that this binary had been replaced with xiloader
2.1.1 (MD5 `44FE5F23BF76E4E847946B5B76F1E061`) was inaccurate. That swap was never actually
executed on this machine. No such binary exists under `F:\ffxi\` at the expected size.

## Why the launch hangs

This old bootloader:

1. Opens a TCP connection to the LSB auth server (port 54231). "Connected to server!"
   prints — this is just the socket handshake, not full credential exchange.
2. Prints an interactive menu — "1. Login / 2. Create New Account" — and calls `fgets()`
   (or equivalent) on stdin, waiting for a keystroke.
3. Does NOT consume `--user` / `--password` command-line flags to auto-advance through
   the menu. Those flags only pre-fill the username/password prompts that appear AFTER
   the menu selection.

When Ashita is the launcher, the bootloader's console is attached to Ashita's child
process without an interactive user, so the `fgets()` call blocks forever. `ffximain.dll`
is never loaded, `DirectInput8Create` is never invoked, and no game window appears.

In the Ashita log:

```
[D] AshitaCore::Initialize   Begin
[D] ... 9 Core modules Initialize ...
[D] AshitaCore::Initialize   End
```

… and that is the end of the log. `Mine_DirectInput8Create` never fires.

## What is actually confirmed working

| Layer | Status |
|---|---|
| MariaDB `accounts.password` hash fixed for guest rows | WORKING (prior session, verified) |
| LSB xi_connect listening on 54230/54231 | WORKING |
| LSB xi_map listening on 54001 | WORKING |
| LSB xi_search listening on 54002 | WORKING |
| MariaDB on 3306, LSB daemons connected | WORKING |
| Ashita v3.1.0.3 launcher | WORKING |
| Ashita.dll injection via injector.exe | WORKING |
| AshitaCore + 9 modules Initialize | WORKING |
| TCP handshake from bootloader to 54231 | WORKING |
| End-to-end auth + character-select reach | **NOT WORKING** — blocked on menu |

## Corrective path forward

### Option A — install real xiloader 2.1.1 (preferred, matches upstream LSB)

1. Fetch the release binary:
   - `https://github.com/LandSandBoat/xiloader/releases/tag/v2.1.1` (LSB-pinned fork), or
   - `https://github.com/atom0s/xiloader/releases` (upstream)
2. Verify hash before installing:
   - Expected MD5: `44FE5F23BF76E4E847946B5B76F1E061`
   - Expected size: ~1 MB
3. Back up the current bootloader:
   ```powershell
   Copy-Item 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe' 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak'
   ```
4. Copy xiloader 2.1.1 as `F:\ffxi\Ashita\ffxi-bootmod\pol.exe`.
5. Launch Ashita -> Altana. xiloader 2.1.1 auto-consumes `--user`/`--password`, skips the
   menu, and chain-loads `ffximain.dll` from the retail FFXI install.

### Option B — wrap the old bootloader with a stdin feeder

If the network blocks GitHub or you want to keep the DarkStar-era binary, write a small
AutoIt or PowerShell wrapper that:

1. Starts `pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin` with
   a piped stdin.
2. Waits for the `Enter a selection:` prompt.
3. Writes `1\r` to the child's stdin to pick Login.
4. Writes `\r\r` at subsequent prompts so the pre-filled `--user`/`--password` accept by
   default.

Option A is cleaner and what upstream LSB documentation assumes. Option B is achievable
in ~40 lines of AutoIt but leaves technical debt.

## Verification once Option A is applied

Run from any shell:

```powershell
F:\ffxi\Ashita\ffxi-bootmod\pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin
```

Expected output on real xiloader 2.1.1:

```
==========================================================================
xiloader - a FFXI loader for LandSandBoat servers
==========================================================================
[INFO] Attempting to authenticate...
[INFO] Successfully logged in as GUESTCL1!
[INFO] Connected to server!
[INFO] Launching the game...
```

… and the FFXI game window should appear within 5-10 seconds, showing the character
select screen populated from LSB's `chars` table.

## Session artifacts

On the Windows machine at `F:\ffxi\deploy\`:

| File | Contents |
|---|---|
| `xiloader-help.txt` | Bootloader identity proof |
| `launch-status.log` | Full diagnostic transcript (processes, ports, logs) |
| `relaunch.log` | Transcript of the kill + patch + relaunch |
| `relaunch-verbose.ps1` | Idempotent relaunch script (without --hide) |
| `diag-launch.ps1` | Diagnostic snapshot script |
| `patch-v3-bootcmd.ps1` | Earlier script that patched `boot_command` |
| `SESSION-STATUS-2026-04-20-v2.md` | Human-readable recap mirror of this doc |

In the Ashita config:

- `F:\ffxi\Ashita\config\boot\Private Server.xml` — current, `--hide` removed
- `F:\ffxi\Ashita\config\boot\Private Server.xml.20260420230306.bak` — backup

## Process hygiene note

The relaunch script's `Stop-Process -Force` calls did not terminate PIDs 4200 (Ashita) and
24816 (pol) from the prior session — they survived and were still holding the old TCP
sockets during the 23:03 diagnostic. Likely cause: running non-elevated cannot terminate
processes owned by a different Windows session or integrity level. Recommendation: reboot
between retries, or run the relaunch script from an elevated PowerShell.

## No LSB state was mutated

- No DB writes this session (auth-hash fix was last session, already verified).
- No file deletions.
- No permission changes.
- Only config change: `--hide` flag removed from `boot_command`; backup preserved.
