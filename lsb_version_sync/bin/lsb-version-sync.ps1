# lsb-version-sync.ps1 - PowerShell wrapper around `python -m lsb_version_sync`.
# The whole point of this module is that it stays portable: Python does the
# actual work, this script just sets env vars and forwards subcommands. Run
# with no args for `status`; pass `sync`, `detect`, etc. to forward.
#
# Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\lsb_version_sync\bin\lsb-version-sync.ps1 status
#   ... -File ... sync               # real run
#   ... -File ... sync --dry-run     # report only

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args = @('status')
)

$ErrorActionPreference = 'Continue'

# Module path: parent of this script / ../../lsb_version_sync (the package root).
$thisDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgRoot  = Resolve-Path (Join-Path $thisDir '..')

# Let Python import the package without needing `pip install`.
$env:PYTHONPATH = ($pkgRoot.Path) + ';' + ($env:PYTHONPATH)

# Defaults if caller didn't set them.
if (-not $env:LSB_LOGIN_LUA)  { $env:LSB_LOGIN_LUA  = 'F:\ffxi\server\settings\login.lua' }
if (-not $env:LSB_VSYNC_LOG) { $env:LSB_VSYNC_LOG = 'F:\ffxi\deploy\lsb-version-sync.log' }

# Resolve python; prefer `py -3` on Windows where it's the launcher.
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host "python not on PATH; install Python 3.9+ to use lsb-version-sync" -ForegroundColor Red
    exit 127
}

& $py.Source -m lsb_version_sync @Args
exit $LASTEXITCODE
