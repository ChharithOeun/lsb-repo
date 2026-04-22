# Session 2026-04-21 v4 — Retail FFXI chain end-to-end VERIFIED

This session (continuation of 2026-04-20 v3) closes the task **"Wire up retail
FFXI path from Steam install."** xiloader 2.1.1 now launches the retail Steam
FFXI client end-to-end — from boot-loader through `FFXiMain.dll` load — and
puts a live FINAL FANTASY XI window on screen. The remaining blocker is a
server-side version-lock mismatch (FFXI-3331), tracked as task #7.

## TL;DR

- xiloader 2.1.1 (MD5 `44FE5F23BF76E4E847946B5B76F1E061`) at
  `F:\ffxi\Ashita\ffxi-bootmod\pol.exe` is correct.
- The retail Steam FFXI install is at
  `C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI`
  (with `FFXiMain.dll` alongside).
- `examples/finish5.ps1` is the canonical end-to-end smoke test: stages
  xiloader next to `FFXiMain.dll`, launches it with CWD = game dir, and
  captures xiloader stdout/stderr to a file.
- `finish5.xiloader-stdout.log` confirms full handshake:
  `Autologin activated → Successfully logged in as GUESTCL1 → Connected to
  server → Hairpin fix applied → Resolving pp000.pol.com` — i.e. the game
  handed off from xiloader into its own PlayOnline update/version check.
- A FINAL FANTASY XI window appeared on screen showing
  **`Error code: FFXI-3331 — The game's data has been updated.`** That is
  the LSB `login_version_lock` / `CLIENT_VER` mismatch, not a loader-chain
  bug. Client → xiloader → FFXiMain chain is working.

## What v3 left open vs. what v4 confirms

v3 confirmed the binary at the deploy path was real xiloader 2.1.1 and that
`GUESTCL1/guestpass` auth completes against LSB. It did not prove that the
retail Steam client can actually be launched by xiloader — that part was
deferred because the retail game-dir path was uncertain on the live box.

v4 resolves that:

1. **Retail path is certain.** Steam installs the retail FFXI into
   `C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI`.
   `FFXiMain.dll` lives in that folder (sibling of `PlayOnlineViewer`, not
   inside it — this tripped v2 and v5 of the finder scripts).
2. **xiloader can chain-load the retail client from there.** With CWD set to
   that game dir and `xiloader.exe` copied alongside `FFXiMain.dll`, xiloader
   finds the DLL, authenticates, and hands off into the game. `finish5.log`
   shows the xiloader process alive for 30 s with window title
   `FINAL FANTASY XI`, and `finish5.xiloader-stdout.log` shows xiloader
   completing the full boot sequence (Mbed TLS init → resolve server → auth →
   connect → hairpin fix → host resolves for `pp000.pol.com`).
3. **The game window appears on screen.** Observed visually during the run:
   FINAL FANTASY XI logo + error dialog. The game DID start drawing — it only
   failed the post-auth version check.

## The three-process timeline, annotated

```
finish5.ps1 launches xiloader.exe in retail game dir
    ↓
xiloader prints banner "LandSandBoat Boot Loader (c) 2021-2026 ... (v2.1.1)"
    ↓
xiloader resolves 127.0.0.1 → connects to 127.0.0.1:54231 (LSB login_auth_port)
    ↓
xiloader: "Successfully logged in as GUESTCL1!" + "Connected to server!"
    ↓
xiloader applies hairpin fix (redirects SE's pol.com hosts to 127.0.0.1)
    ↓
xiloader LoadLibrary("FFXiMain.dll") from its CWD
    ↓
FFXiMain.dll starts; sets window title "FINAL FANTASY XI"
    ↓
FFXiMain.dll starts version-check dialog with server
    ↓
Server's login_version_lock / CLIENT_VER doesn't match client patch level
    ↓
Game shows "Error code: FFXI-3331 — game data has been updated"
```

Everything up to and including the FFXiMain.dll window is **working**. The
failure is one rung higher.

## Next session — resolving FFXI-3331 (task #7)

FFXI-3331 is LSB's way of rejecting a client whose version string isn't on its
allow-list. Depending on LSB fork and config location, fix is one of:

- **login config**: `settings/default/login.lua` (or the
  `settings/network.lua` in newer LSB) — look for `LOGIN_VERSION_LOCK`,
  `LOGIN_CLIENT_VER`, or `CLIENT_VER`. Set the version string to the exact
  value the retail Steam client reports, or set the lock mode to "any".
- **login_data_port handler**: older LSB forks check `CLIENT_VER` inside the
  login auth worker. Dump the client's version packet (by adding a debug
  print in `login.cpp`) and copy that string into the config.
- **disable the check**: if the fork supports it, set
  `LOGIN_VERSION_LOCK = 0` to accept any client version. Only use on a
  private box.

To find the active config on the live box, search under the LSB repo for
`VERSION_LOCK|CLIENT_VER|FFXI-3331`. Then patch + reload the login server
worker (NOT the whole LSB) and re-run `finish5.ps1`.

## Files added/updated in this session

| File | Purpose |
|---|---|
| `examples/finish5.ps1` | Canonical end-to-end smoke test with stdout/stderr capture; supersedes finish4 |
| `examples/diag-final.ps1` | Post-run snapshot: process list / `FFXiMain.dll` module scan / LSB netstat |
| `docs/SESSION-2026-04-21-v4-RETAIL-CHAIN-VERIFIED.md` | This document |

The live box also has, under `F:\ffxi\deploy\`:

- `finish5.log` — full transcript of the v4 run
- `finish5.xiloader-stdout.log` — xiloader's own prints
- `finish5.xiloader-stderr.log` — xiloader's stderr (empty in this run)
- `diag-final.log` — post-run state snapshot

## Verified evidence (from finish5.xiloader-stdout.log, 2026-04-21 07:36)

```
[04/21/26 07:36:00] =========================================================
[04/21/26 07:36:00] DarkStar Boot Loader (c) 2015 DarkStar Team
[04/21/26 07:36:00] LandSandBoat Boot Loader (c) 2021-2026 LandSandBoat Team (v2.1.1)
[04/21/26 07:36:00] Using Mbed TLS 3.6.5
[04/21/26 07:36:00] Resolving '127.0.0.1' ...
[04/21/26 07:36:00] Resolved server address to '127.0.0.1:54231'
[04/21/26 07:36:00] Autologin activated!
[04/21/26 07:36:01] Successfully logged in as GUESTCL1!
[04/21/26 07:36:01] Connected to server!
[04/21/26 07:36:02] Hairpin fix applied!
[04/21/26 07:36:06] Resolving host: ffxi00.pol.com
[04/21/26 07:36:06] Resolving host: 127.0.0.1
[04/21/26 07:36:06] Resolving host: pp000.pol.com
```

And the 6-second polling transcript from finish5.log:

```
  ..5s  alive pid=18884 title='FINAL FANTASY XI'
  ..10s alive pid=18884 title='FINAL FANTASY XI'
  ..15s alive pid=18884 title='FINAL FANTASY XI'
  ..20s alive pid=18884 title='FINAL FANTASY XI'
  ..25s alive pid=18884 title='FINAL FANTASY XI'
  ..30s alive pid=18884 title='FINAL FANTASY XI'
```

The xiloader process stays alive for the whole 30-second polling window
with the FFXI window title set — direct evidence the chain-load succeeded.

## Status of the task list after this session

- #6 "Wire up retail FFXI path from Steam install" → **completed**
- #7 "Resolve FFXI-3331 client/server version mismatch" → **pending** (new)
