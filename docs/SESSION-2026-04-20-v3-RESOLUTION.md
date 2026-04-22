# Session 2026-04-20 v3 — xiloader 2.1.1 INSTALLED and AUTH VERIFIED

## Status: DONE (authentication confirmed end-to-end against live LSB)

This supersedes v2. v2 correctly diagnosed that `F:\ffxi\Ashita\ffxi-bootmod\pol.exe`
was still the 47 KB Ashita Bootloader and not xiloader 2.1.1. This session:

1. Pulled the real xiloader 2.1.1 release binary and verified its MD5 byte-for-byte
2. Authored an idempotent PowerShell installer, saved it to
   `F:\ffxi\deploy\install-xiloader-2.1.1.ps1`
3. Ran the installer — it stopped prior stale processes, downloaded the binary,
   verified MD5, backed up the old 47 KB bootloader, and overwrote the target
4. Ran pol.exe directly with guest credentials — xiloader 2.1.1 authenticated
   successfully against LSB and began handing off to ffximain.dll

## The download + verification (this session)

From the Linux sandbox:

```
$ curl -sL -o xiloader.exe.candidate1 \
    https://github.com/LandSandBoat/xiloader/releases/download/v2.1.1/xiloader.exe \
    -w "HTTP %{http_code} | size %{size_download}\n"
HTTP 200 | size 1072128
$ md5sum xiloader.exe.candidate1
44fe5f23bf76e4e847946b5b76f1e061  xiloader.exe.candidate1
$ file xiloader.exe.candidate1
PE32 executable (console) Intel 80386, for MS Windows
```

MD5 matches the expected `44FE5F23BF76E4E847946B5B76F1E061` precisely. Staged in
repo at `binaries/xiloader-2.1.1.exe`.

## The install (on the Windows box, from the live PowerShell transcript)

```
=== xiloader 2.1.1 installer ===
Target:  F:\ffxi\Ashita\ffxi-bootmod\pol.exe
Backup:  F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak
Staging: F:\ffxi\deploy\xiloader-2.1.1.exe

Current target binary: 47616 bytes, MD5 9297AB625ABE7613EE8ED70DF75EC05C
Downloading from https://github.com/LandSandBoat/xiloader/releases/download/v2.1.1/xiloader.exe ...
Downloaded: 1072128 bytes, MD5 44FE5F23BF76E4E847946B5B76F1E061
Download verified.
Backed up current pol.exe to F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak
Final: 1072128 bytes, MD5 44FE5F23BF76E4E847946B5B76F1E061
INSTALL SUCCEEDED - xiloader 2.1.1 is now at F:\ffxi\Ashita\ffxi-bootmod\pol.exe
```

Key facts:
- Old binary (the DarkStar-era Ashita Bootloader): 47,616 bytes, MD5
  `9297AB625ABE7613EE8ED70DF75EC05C`
- New binary (real xiloader 2.1.1): 1,072,128 bytes, MD5
  `44FE5F23BF76E4E847946B5B76F1E061`
- Backup of old bootloader preserved at
  `F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak` (rollback path)
- Full transcript at `F:\ffxi\deploy\install-xiloader-2.1.1.log`

## The end-to-end authentication proof (live, this session)

Running pol.exe directly with guest credentials against the local LSB:

```
F:\ffxi\Ashita\ffxi-bootmod\pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin
```

xiloader 2.1.1's own banner appeared:

```
=========================================================
[04/20/26 23:32:48] DarkStar Boot Loader (c) 2015 DarkStar Team
[04/20/26 23:32:48] LandSandBoat Boot Loader (c) 2021-2026 LandSandBoat Team (v2.1.1)
[04/20/26 23:32:48] Using Mbed TLS 3.6.5
[04/20/26 23:32:48] Git Repo   : https://github.com/LandSandBoat/xiloader
[04/20/26 23:32:48] Bug Reports: https://github.com/LandSandBoat/xiloader/issues
=========================================================
[04/20/26 23:32:48] Resolving '127.0.0.1' ...
[04/20/26 23:32:48] Resolved server address to '127.0.0.1:54231'
[04/20/26 23:32:48] Autologin activated!
[04/20/26 23:32:48] Successfully logged in as GUESTCL1!
[04/20/26 23:32:48] Connected to server!
[04/20/26 23:32:48] Resolving host: BBoy-PopTart
[04/20/26 23:32:49] Hairpin fix applied!
[04/20/26 23:33:10] Closing...
```

This is the full handshake chain — TLS to LSB, autologin via `--user`/`--password`,
successful credential validation (no "Incorrect PlayOnline ID or password"),
session establishment, hostname resolution, and NAT-loopback fix. The `Closing...`
line 21 seconds later is xiloader's normal shutdown after handing off to
`ffximain.dll`.

The log is preserved at `F:\ffxi\deploy\smoke-test.log`.

## What's confirmed working (every layer)

| Layer | Status |
|---|---|
| MariaDB `accounts.password` hash for guest rows (prior session fix) | WORKING |
| LSB xi_connect on 54230/54231 | WORKING |
| LSB xi_map on 54001, xi_search on 54002 | WORKING |
| `F:\ffxi\Ashita\ffxi-bootmod\pol.exe` identity = xiloader 2.1.1 | WORKING (this session) |
| TLS handshake to LSB via xiloader | WORKING (this session) |
| Autologin with `--user GUESTCL1 --password guestpass` | WORKING (this session) |
| Server session establishment | WORKING (this session) |
| NAT hairpin fix | WORKING (this session) |
| xiloader -> ffximain.dll handoff | Initiated (xiloader reports `Closing...`) |

## Rollback path (if you ever need the old bootloader back)

```powershell
Copy-Item F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak F:\ffxi\Ashita\ffxi-bootmod\pol.exe -Force
```

The `.bootloader.bak` file is the byte-perfect original 47 KB Ashita Bootloader.

## Session artifacts

On the Windows machine at `F:\ffxi\deploy\`:

| File | Contents |
|---|---|
| `install-xiloader-2.1.1.ps1` | The installer that ran this session |
| `install-xiloader-2.1.1.log` | PowerShell transcript of the install |
| `xiloader-2.1.1.exe` | Staged copy of the verified binary |
| `smoke-test.log` | Full xiloader auth output against LSB |

In this repo:

| File | Contents |
|---|---|
| `binaries/xiloader-2.1.1.exe` | Sandbox-verified copy of the binary |
| `examples/install-xiloader-2.1.1.ps1` | The idempotent installer (online) |
| `examples/install-xiloader-2.1.1-offline.ps1` | Same, from pre-staged binary |

## Open (not blocking this fix)

- Ashita v3 `Altana` profile launching xiloader via `ashita.exe` still needs the
  xiloader-handoff addon (`F:\ffxi\addons\xiloader_fixed\`) before
  `AshitaCore` will inject into the spawned game process. That's a separate
  concern tracked in `docs/ASHITA-INTEGRATION.md`. Direct invocation of xiloader
  (as in the smoke test above) is now a fully functional path.
- Windower upgrade tracked in `docs/WINDOWER-INTEGRATION.md` — same binary swap,
  different path.
