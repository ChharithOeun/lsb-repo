# Ashita v4 — Altana (Private Server) Profile Setup

This document captures the correct boot chain for running the retail FFXI client against a local LandSandBoat server using Ashita v4.

## The mental model (read this first)

Ashita is **not** an auth helper. It's a DLL-injection host. Its job is to start FFXI (by launching `pol.exe`) and then inject the Ashita runtime into that process so addons and plugins take effect.

xiloader **is** the auth helper. Its job is:
1. Open a TCP connection to the LSB `xi_connect` port.
2. Send a JSON handshake `{command, username, password, version, otp, trust_token}`.
3. On success, spawn the real retail `pol.exe` with the session parameters baked in so the client connects straight to `xi_map` / `xi_search`.

The two tools are complementary — not interchangeable. xiloader runs **first**, then Ashita attaches to whatever xiloader spawned.

## What was wrong

The previous `Private Server.xml` profile told Ashita:
> "Boot `polboot.exe`. Inject your DLLs into it."

`polboot.exe` is SE's thin bootstrapper — it exits in under a second and doesn't speak LSB's auth protocol, so Ashita had nothing to inject into and the `xi_connect` side never saw a handshake.

Pointing `boot_file` at the new xiloader 2.1.1 (`ffxi-bootmod\pol.exe`) gets half the way there: xiloader authenticates fine, but Ashita's injector still fails because xiloader itself isn't an injectable target — it's a short-lived auth process that hands off to a newly spawned `pol.exe`.

## The correct chain

We need Ashita to:
1. Run `ffxi-bootmod\pol.exe` (xiloader) as a pre-launch step.
2. Wait for it to spawn the retail `pol.exe` (the real FFXI client).
3. Inject into that spawned `pol.exe`.

Ashita's `boot_file` + `boot_command` alone don't cover step 2 — there's no built-in "wait for spawned child" hook. Two clean options:

### Option 1 — Use `xiloader_fixed` addon (recommended)
Install the `xiloader_fixed` Ashita addon, which is purpose-built for this chain. It runs xiloader internally, intercepts the spawned `pol.exe`, and hands it to Ashita's injector. Configure the profile to point `boot_file` at the retail `pol.exe` and enable the addon in the profile's addon list.

### Option 2 — Launcher script wrapper
Write a tiny `.bat` that runs xiloader to completion, then launches Ashita with the retail `pol.exe` pre-armed. Not ideal because Ashita's injector timing is finicky, but works for smoke tests.

## Current state (as of 2026-04-20)

Applied in this session:

| Setting | Old | New |
|---|---|---|
| `Private Server.xml` → `boot_file` | `C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\polboot.exe` | `F:\ffxi\Ashita\ffxi-bootmod\pol.exe` |
| `Private Server.xml` → `boot_command` | `--server 127.0.0.1` | (unchanged) |
| `Private Server.xml` → `config_name` | `Altana` | (unchanged) |
| `ffxi-bootmod\pol.exe` | xiloader 1.0.0.4 | xiloader 2.1.1 |

With these settings, xiloader authenticates successfully (verified in `xiloader-upgrade.log`), but Ashita's Play button still throws because of the injection timing issue above.

## Built this session — `xiloader_fixed` addon (Option 1)

The addon now lives in the repo at `addons/xiloader_fixed/`. It is a
self-contained Ashita v3 Lua addon that:

- Reads its config from `addons/xiloader_fixed/settings/settings.lua`
- On `load` (after a small delay), spawns xiloader 2.1.1 with the
  configured server / user / pass / hairpin / hide flags
- Tracks the spawned PID so `/xilfix kill` can clean up
- Exposes `/xilfix status | set | save | run | kill | help` at the
  in-game console

Install with:
```powershell
powershell -ExecutionPolicy Bypass -File examples\install-ashita-xiloader-addon.ps1
```

That script:
1. Backs up `Private Server.xml` to `config\_backups\`
2. Re-points `boot_file` at the **retail** `pol.exe`
   (`C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe`)
3. Sets `boot_command` to `--server 127.0.0.1`
4. Copies `addons/xiloader_fixed` into `<AshitaRoot>\addons\`
5. Best-effort adds `xiloader_fixed` to the Altana profile's addon list
   (manual enable via Ashita's config UI is the fallback)

Resulting profile:
```xml
<setting name="boot_file">C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe</setting>
<setting name="boot_command">--server 127.0.0.1</setting>
<setting name="config_name">Altana</setting>
```
plus an `<addons>` entry referencing `xiloader_fixed`.

## Built this session — `Launch-Altana` wrapper (Option 2)

For users who don't want to enable an addon, the repo ships a
launcher pair at `examples/Launch-Altana.bat` and
`examples/Launch-Altana.ps1`. Both do the same thing:

1. Spawn xiloader 2.1.1 with the configured credentials and `--hairpin
   --hide`
2. Wait ~1 second for it to authenticate and spawn the retail pol.exe
3. Launch `ashita.exe --boot "Private Server"` so Ashita injects into
   the live pol.exe

The PS1 form additionally diffs running `pol.exe` PIDs before/after to
log whether xiloader actually spawned a child, and writes a transcript
to `F:\ffxi\deploy\altana-launch.log`.

## Workaround that always works (skips Ashita entirely)

Launch xiloader directly from a shortcut or the control panel's
Launch-FFXI.bat. No Ashita features (no addons, no plugins), but
you reach character select:
```
F:\ffxi\Ashita\ffxi-bootmod\pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin --hide
```

## References
- `F:\ffxi\server\src\login\auth_session.h` line 68 — version constant
- `F:\ffxi\server\src\login\auth_session.cpp` lines 148-163 — handshake parsing, version gate
- `F:\ffxi\server\src\login\auth_session.cpp` lines 602-637 — BCrypt + legacy PASSWORD() fallback
- `F:\ffxi\Ashita\config\boot\Private Server.xml` — profile being edited
- `addons/xiloader_fixed/xiloader_fixed.lua` — the addon source
- `addons/xiloader_fixed/README.md` — addon usage + troubleshooting
- `examples/install-ashita-xiloader-addon.ps1` — one-shot installer
- `examples/Launch-Altana.bat`, `examples/Launch-Altana.ps1` — wrapper alternative
