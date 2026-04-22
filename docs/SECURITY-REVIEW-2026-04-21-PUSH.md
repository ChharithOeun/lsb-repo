# Security Review — 2026-04-21 Session (pre-push)

Scope: all files added or modified in this session, prior to initial `git push`
to the new GitHub remote. Triggered by task #32 before completing task #27
(init git remote).

## Files reviewed

- `SYNC.bat`
- `DETECT.bat`, `DETECT2.bat`, `DETECT3.bat`
- `SIDECAR_RESTART.bat`, `SIDECAR_RESTART.ps1`
- `chharbot/bin/detect_probe.py`, `detect_probe2.py`, `detect_probe3.py`
- `chharbot/bin/probe.py` (admin-token loading added this session)
- `lsb_version_sync/lsb_version_sync/config.py` (patch2.cfg added)
- `.gitignore` (tightened)

## Findings

| # | Severity | File | Issue | Status |
|---|---|---|---|---|
| 1 | NONE | all new `.py`/`.ps1`/`.bat` | Hard-coded secrets? | CLEAN — grep for `password\|token\|api_key\|ghp_\|github_pat_\|sk-\|AKIA\|PRIVATE KEY` returns zero matches outside well-known file-based auth patterns and dev-only test credentials documented in `SECURITY-REVIEW.md`. |
| 2 | NONE | `SIDECAR_RESTART.ps1` | Admin token handling | Token is read with `Get-Content -LiteralPath $adminToken -Raw`, used only in a header to `http://127.0.0.1:27116/version_sync/status`, and never written back out. |
| 3 | NONE | `detect_probe3.py` | Path traversal | Walks a fixed `ROOTS` allowlist (`C:\Program Files (x86)\Steam\...`, `F:\ffxi\*`). No user-controlled paths. Per-file size cap of 256 KB. |
| 4 | NONE | `config.py` | Command injection via env var | `LSB_VSYNC_DLL` is `.split(os.pathsep)` then used only as `Path(s).exists()`. Never passed to a shell. |
| 5 | NONE | all `.bat` | `cd /d "%~dp0"` | All wrappers cd to the script's own directory first — safe from directory-hijacking. |
| 6 | NONE | all `.py`/`.ps1` | `Invoke-Expression` / `iex` / `shell=True` / `os.system` / `eval` / `exec` | Zero hits in new code. Only pre-existing unrelated match is an Ashita-embedded Lua string in `examples/deploy-xiloader-fixed-addon.ps1:97`. |
| 7 | LOW  (fixed) | `.gitignore` | `.env` and `*.pem`/`*.key` not explicitly excluded | Added `.env`, `.env.*`, `*.pem`, `*.key` as defense-in-depth. Repo does not currently contain any of these; the user's PAT `.env` lives at `F:\ffxi\deploy\.env` which is outside the repo root. |

## Checks performed

```
grep -riE '(password|secret|token|api_key|ghp_|github_pat_|sk-|AKIA|PRIVATE KEY)' \
    new-files
grep -rE '(Invoke-Expression|iex |eval\(|exec\(|shell=True|os\.system)' new-files
grep -rE 'curl.*\|.*(sh|bash|pwsh)' new-files   # zero hits
find lsb-repo -name '.env*' -o -name '*.pem' -o -name '*.key'   # zero hits
```

## Ready-to-push verdict

**CLEAR.** No secrets in working tree, no injection sinks in new code, token
handling matches the existing file-based pattern established in the 2026-04-21
v5 security review. `.gitignore` has been tightened to catch any `.env` files
that might be dropped into the repo later.

The remote-init step in task #27 must still ensure the GitHub PAT is used only
via an ephemeral `https://<pat>@github.com/...` URL during `git push` and is
scrubbed from `.git/config` afterward — handled in `GIT_INIT.ps1`.
