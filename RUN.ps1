# RUN.ps1 - one-click bootstrap for the LSB repo on the live box.
#
# Right-click -> "Run with PowerShell" from File Explorer. Logs to
# F:\ffxi\lsb-repo\RUN.log so the assistant can tail it.
#
# Does, in order:
#   1. Clean out the pytest cache that tagged along from the sandbox.
#   2. Run examples\deploy-full-stack.ps1 against THIS repo root.
#   3. Run chharbot\bin\smoke-test.ps1 to verify.
#
# Safe to re-run.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'RUN.log'

Start-Transcript -Path $LogPath -Force | Out-Null

function Section($msg) { Write-Host "=== $msg ===" -ForegroundColor Green }
function W($msg) { Write-Host $msg -ForegroundColor Yellow }

Section "chharbot / LSB live-box bootstrap"
Write-Host ("  RepoRoot : {0}" -f $RepoRoot)
Write-Host ("  LogPath  : {0}" -f $LogPath)
Write-Host ("  started  : {0}" -f (Get-Date))
Write-Host ""

# 1. Remove sandbox-dropped pytest caches.
Section "step 1 - tidy sandbox leftovers"
Get-ChildItem -Path $RepoRoot -Recurse -Directory -Filter 'pytest-cache-files-*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        Write-Host ("  removing {0}" -f $_.FullName)
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
Get-ChildItem -Path $RepoRoot -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""

# 2. Deploy-full-stack.
Section "step 2 - deploy-full-stack.ps1"
$deploy = Join-Path $RepoRoot 'examples\deploy-full-stack.ps1'
if (-not (Test-Path $deploy)) {
    Write-Host "FATAL: deploy-full-stack.ps1 not found at $deploy" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 2
}
# Note: -FixVerLock and -RunVersionSync are mutually exclusive.
# -RunVersionSync = auto-match retail's CLIENT_VER (preserves enforcement).
# To hard-disable the version lock instead, re-run RUN.ps1 after editing this
# line to use -FixVerLock in place of -RunVersionSync.
& $deploy -RepoRoot $RepoRoot -RunVersionSync -StartSidecar
$deployExit = $LASTEXITCODE
Write-Host ""
Write-Host ("  deploy exit : {0}" -f $deployExit) -ForegroundColor (&{ if ($deployExit -eq 0) {'Green'} else {'Red'} })
Write-Host ""

# 3. Smoke test.
Section "step 3 - chharbot smoke-test.ps1"
$smoke = Join-Path $RepoRoot 'chharbot\bin\smoke-test.ps1'
if (-not (Test-Path $smoke)) {
    Write-Host "FATAL: smoke-test.ps1 not found at $smoke" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 3
}
try {
    & $smoke -PullIfMissing
    $smokeExit = $LASTEXITCODE
} catch {
    Write-Host ("  smoke test threw: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $smokeExit = 1
}
Write-Host ""
Write-Host ("  smoke exit  : {0}" -f $smokeExit) -ForegroundColor (&{ if ($smokeExit -eq 0) {'Green'} else {'Red'} })
Write-Host ""

Section "done"
Write-Host ("  finished : {0}" -f (Get-Date))
Write-Host ("  deploy   : {0}" -f $deployExit)
Write-Host ("  smoke    : {0}" -f $smokeExit)
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Cyan

Stop-Transcript | Out-Null

# Keep the window open so the user can read the result.
if ($Host.Name -eq 'ConsoleHost') { [void][System.Console]::ReadKey($true) }
