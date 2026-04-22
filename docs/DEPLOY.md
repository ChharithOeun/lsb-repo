# DEPLOY — how to run the auth fix on the Chharbot Windows box

One page. Follow top to bottom.

## Step 0 — prereq staging (only if not done yet)

The addon-install script expects a xiloader-handoff Ashita addon to be present at:
```
F:\ffxi\addons\xiloader_fixed\
```
If that folder doesn't exist yet, stage it before running the orchestrator. Community options to consider, in rough order of fit for LSB:

1. `xiloader_fixed` (LSB-maintained handoff addon, if published)
2. `ashita-xiloader-addon` / `xiloader-ashita` (community forks)
3. A minimal custom addon that just waits for the spawned `pol.exe` and hands it to Ashita's injector

If none are ready, the orchestrator will skip the Ashita step cleanly and continue with the Windower upgrade and verification — nothing in this deploy is destructive.

## Step 1 — copy the scripts bundle onto the Windows box

Copy the entire `examples\` folder from this repo to any writable location, e.g. `F:\ffxi\deploy\`. The scripts are path-independent except for their dependencies on each other (they all live in the same folder).

## Step 2 — run

Two options, pick one:

**Double-click:** `run-all-fixes.bat`

**PowerShell:**
```powershell
powershell -ExecutionPolicy Bypass -File .\run-all-fixes.ps1
```

## Step 3 — read the summary

The orchestrator prints a colored summary at the end:

```
Ashita addon install          PASS | SKIP (addon source not staged) | FAIL
Windower xiloader upgrade     PASS | SKIP (prereq missing)          | FAIL
Guest login verification      PASS                                   | FAIL
```

- **All three PASS** → you're done. Launch Ashita → Altana → Play and you should hit character select.
- **Any FAIL** → the step-specific output above the summary tells you why. The other steps still ran.
- **SKIP on the addon step** → stage the addon at `F:\ffxi\addons\xiloader_fixed` and re-run.
- **SKIP on Windower** → Windower isn't installed on this machine (fine if you only use Ashita).

## Step 4 — smoke test manually

If you want to double-check independently of the verifier:
```
F:\ffxi\Ashita\ffxi-bootmod\pol.exe --server 127.0.0.1 --user GUESTCL1 --password guestpass --hairpin --hide
```
Expected last lines:
```
Successfully logged in as GUESTCL1!
Connected to server!
```

## Rollback

Every script keeps a versioned backup:
- Profile/config backups: `F:\ffxi\Ashita\config\_backups\*.bak`
- xiloader binaries: `<xiloader-folder>\xiloader.exe.v<old-version>.bak`
- Password change: the old hash is lost (that's the fix). To revert, change it to whatever you had, or blank it and re-register.

## What doesn't get touched
- MariaDB `accounts` table (the password fix was already applied last session — verify only)
- Any character rows
- Any running LSB daemons
- POL Viewer (explicitly out of scope)
