# xiloader_fixed (Ashita v3 addon)

Bridges xiloader 2.1.x with Ashita v3's injector so the LandSandBoat
Altana profile reaches character select via the normal `ashita.exe →
profile → Play` flow.

## Why it exists

Ashita v3 injects `Ashita.dll` into the process named in `boot_file`. If
`boot_file` points at xiloader, Ashita injects into xiloader — which
then exits a few hundred milliseconds later when it spawns the real
`pol.exe`, so injection is effectively wasted. If `boot_file` points at
the retail `pol.exe` directly, Ashita injects fine but there's no LSB
auth handshake and the client ends up at a SE login prompt that can't
talk to LSB.

This addon splits the work:

- `boot_file` is set to the **retail** `pol.exe`, so Ashita has a real
  injection target.
- The addon runs **xiloader** as a sibling process at addon-load time.
  xiloader does the LSB handshake against `xi_connect`, writes the
  session token where `ffximain` looks for it, then exits.
- Ashita meanwhile injects `Ashita.dll` into the retail `pol.exe`. Once
  the session is live, ffximain consumes the xiloader-supplied token
  and connects straight to `xi_map`.

## Install

```powershell
# from the repo root
Copy-Item -Recurse addons\xiloader_fixed F:\ffxi\Ashita\addons\
```

or use `examples/install-ashita-xiloader-addon.ps1` which also rewrites
`Private Server.xml` and `Altana.xml`.

## Configure (in-game `/` console)

```
/load xiloader_fixed
/xilfix set xiloader F:\ffxi\Ashita\ffxi-bootmod\pol.exe
/xilfix set server   127.0.0.1
/xilfix set user     GUESTCL1
/xilfix set pass     guestpass
/xilfix set hairpin  true
/xilfix set hide     true
/xilfix save
```

Or edit `addons/xiloader_fixed/settings/settings.lua` directly.

## Commands

| Command | What it does |
|---|---|
| `/xilfix status` | Show current config + last spawn result. |
| `/xilfix set <k> <v>` | Update one of: server, user, pass, xiloader, hairpin, hide, autostart. |
| `/xilfix save` | Persist current config to settings.lua. |
| `/xilfix run` | Fire xiloader against the current settings (manual mode). |
| `/xilfix kill` | Kill any xiloader child processes this addon spawned. |
| `/xilfix help` | List the commands. |

## Expected log output

When everything is wired correctly the in-game log shows:

```
[xiloader_fixed] loaded — addon version 1.0.0
[xiloader_fixed] Launching xiloader: "F:\ffxi\Ashita\ffxi-bootmod\pol.exe" --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin --hide
[xiloader_fixed] xiloader spawned (PID 12345). Authenticating against 127.0.0.1 ...
```

The xiloader console (suppressed by `--hide`) writes the same handshake
output to its own log; copy it to `F:\ffxi\deploy\altana-smoke-test.log`
during testing for a permanent record.

## Troubleshooting

- **"xiloader binary missing"** — fix `xiloader` setting to point at the
  installed pol.exe (the 1,072,128-byte xiloader 2.1.1 binary).
- **Authenticates but no character select** — check that `boot_file` in
  `Private Server.xml` is the **retail** pol.exe, not xiloader.
- **POL login prompt appears** — the addon didn't fire in time. Re-run
  `/xilfix run` manually before clicking through, or increase `delay_ms`
  in `settings/settings.lua`.

## Compatibility

- Ashita v3.1.0.3 — tested.
- xiloader 2.1.1 — required (older builds fail LSB's hard-coded
  `SupportedXiloaderVersion = {2,1,0}` floor).
- LSB server with `accounts.password` re-hashed via
  `PASSWORD('guestpass')` for guest accounts.

## License

Public domain. Use, modify, ignore, whatever helps you ship.
