# SIDECAR_RESTART.ps1 - kill and relaunch lsb_admin_api so it picks up
# any config.py edits (e.g. new DEFAULT_DLL_CANDIDATES entries).
#
# The sidecar is launched by deploy-full-stack.ps1 -StartSidecar, which does:
#   Start-Process python -ArgumentList @('-m', 'uvicorn',
#       'lsb_admin_api.server:app', '--host', '127.0.0.1', '--port', '27116')
#       -WorkingDirectory <repo>/sidecar -WindowStyle Minimized
#
# This script mirrors that for restart.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'SIDECAR_RESTART.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($m) { Write-Host "=== $m ===" -ForegroundColor Green }
function W($m)       { Write-Host $m -ForegroundColor Yellow }

Section "sidecar restart"
Write-Host ("  RepoRoot : {0}" -f $RepoRoot)
Write-Host ("  started  : {0}" -f (Get-Date))

# 1. Find process bound to 127.0.0.1:27116.
Section "1. locate existing sidecar"
$pids = @()
try {
    $conns = Get-NetTCPConnection -LocalPort 27116 -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) { $pids += $c.OwningProcess }
} catch {}
$pids = $pids | Sort-Object -Unique
if ($pids.Count -eq 0) {
    Write-Host "  no process currently listening on 27116" -ForegroundColor DarkYellow
} else {
    foreach ($procId in $pids) {
        try {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) {
                Write-Host ("  found PID {0} ({1})" -f $procId, $p.ProcessName)
            } else {
                Write-Host ("  found PID {0} (already gone)" -f $procId)
            }
        } catch {}
    }
}

# 2. Kill them.
Section "2. kill existing sidecar"
foreach ($procId in $pids) {
    try {
        Stop-Process -Id $procId -Force -ErrorAction Stop
        Write-Host ("  killed PID {0}" -f $procId) -ForegroundColor Green
    } catch {
        Write-Host ("  failed to kill PID {0}: {1}" -f $procId, $_.Exception.Message) -ForegroundColor Red
    }
}
Start-Sleep -Seconds 1

# 3. Confirm port is free.
Section "3. confirm port free"
$stillBound = $null
try { $stillBound = Get-NetTCPConnection -LocalPort 27116 -State Listen -ErrorAction SilentlyContinue } catch {}
if ($stillBound) {
    Write-Host "  port 27116 still bound; aborting relaunch" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 2
} else {
    Write-Host "  port 27116 is free" -ForegroundColor Green
}

# 4. Relaunch.
Section "4. relaunch sidecar"
$python      = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Host "  FATAL: python not found on PATH" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 3
}
$sidecarSrc    = Join-Path $RepoRoot 'sidecar\lsb_admin_api'
$sidecarParent = Split-Path $sidecarSrc -Parent
$adminToken    = 'F:\ffxi\deploy\.lsb_admin_token'
$env:LSB_ADMIN_TOKEN_FILE = $adminToken
Write-Host ("  python  : {0}" -f $python.Source)
Write-Host ("  cwd     : {0}" -f $sidecarParent)
Write-Host ("  token   : {0}" -f $adminToken)

Start-Process -FilePath $python.Source `
    -ArgumentList @('-m', 'uvicorn', 'lsb_admin_api.server:app',
                    '--host', '127.0.0.1', '--port', '27116') `
    -WorkingDirectory $sidecarParent `
    -WindowStyle Minimized

Start-Sleep -Seconds 3

# 5. Health probe.
Section "5. /health probe"
try {
    $h = Invoke-RestMethod -Uri 'http://127.0.0.1:27116/health' -TimeoutSec 5
    Write-Host ("  health = {0}" -f ($h | ConvertTo-Json -Compress)) -ForegroundColor Green
} catch {
    Write-Host ("  health probe failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# 6. version_sync/status probe (authenticated).
Section "6. /version_sync/status probe"
try {
    $tok = (Get-Content -LiteralPath $adminToken -Raw).Trim()
    $headers = @{ 'X-Admin-Token' = $tok }
    $s = Invoke-RestMethod -Uri 'http://127.0.0.1:27116/version_sync/status' `
                           -Headers $headers -TimeoutSec 5
    Write-Host ("  version_sync = {0}" -f ($s | ConvertTo-Json -Compress)) -ForegroundColor Green
} catch {
    Write-Host ("  version_sync probe failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ""
Write-Host ("  finished : {0}" -f (Get-Date))
Stop-Transcript | Out-Null

if ($Host.Name -eq 'ConsoleHost') {
    Write-Host "Press any key to close..." -ForegroundColor Cyan
    [void][System.Console]::ReadKey($true)
}
