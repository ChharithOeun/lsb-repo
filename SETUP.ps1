# SETUP.ps1 - install prereqs the live box is missing.
#
# Safe to re-run. Logs to SETUP.log.
#
# Does:
#   1. pip install -e chharbot
#   2. pip install -e lsb_version_sync
#   3. ollama pull llama3.1:8b-instruct-q4_K_M (if missing)
#   4. Re-verify chharbot import + model tag.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'SETUP.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($msg) { Write-Host "=== $msg ===" -ForegroundColor Green }
function OK($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function NO($msg) { Write-Host "  [--] $msg" -ForegroundColor Yellow }
function ER($msg) { Write-Host "  [ER] $msg" -ForegroundColor Red }

Section "live-box setup"
Write-Host "  RepoRoot: $RepoRoot"
Write-Host "  Date    : $(Get-Date)"
Write-Host ""

# --- Python ---
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) { ER "no python found; aborting"; Stop-Transcript | Out-Null; exit 1 }
OK ("python -> {0}" -f $py.Source)

# --- pip install chharbot ---
Section "pip install -e chharbot"
$chharbot = Join-Path $RepoRoot 'chharbot'
if (Test-Path (Join-Path $chharbot 'pyproject.toml')) {
    & $py.Source -m pip install -e $chharbot --disable-pip-version-check 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -eq 0) { OK "chharbot installed" } else { ER "chharbot install failed (exit $LASTEXITCODE)" }
} else { ER "chharbot\pyproject.toml missing" }
Write-Host ""

# --- pip install lsb_version_sync ---
Section "pip install -e lsb_version_sync"
$vsync = Join-Path $RepoRoot 'lsb_version_sync'
if (Test-Path (Join-Path $vsync 'pyproject.toml')) {
    & $py.Source -m pip install -e $vsync --disable-pip-version-check 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -eq 0) { OK "lsb_version_sync installed" } else { ER "lsb_version_sync install failed (exit $LASTEXITCODE)" }
} else { ER "lsb_version_sync\pyproject.toml missing" }
Write-Host ""

# --- ollama model pull ---
Section "ollama model pull"
$model = 'llama3.1:8b-instruct-q4_K_M'
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    NO "ollama not on PATH; skipping model pull"
} else {
    try {
        $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
    } catch {
        NO "ollama daemon not up; starting..."
        Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try { $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3 }
        catch { ER "still cannot reach ollama"; $tags = $null }
    }
    $have = $false
    if ($tags -and $tags.models) {
        foreach ($m in $tags.models) { if ($m.name -eq $model) { $have = $true; break } }
    }
    if ($have) {
        OK "$model already present"
    } else {
        Write-Host ("  pulling {0} -- this is ~4.7 GB, will take a few minutes..." -f $model) -ForegroundColor Yellow
        & $ollama.Source pull $model 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) { OK "model pulled" } else { ER ("ollama pull failed (exit {0})" -f $LASTEXITCODE) }
    }
}
Write-Host ""

# --- Verify ---
Section "verify"
& $py.Source -c "import chharbot; print('  chharbot at:', chharbot.__file__)" 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -eq 0) { OK "chharbot import ok" } else { ER "chharbot still not importable" }

& $py.Source -c "import lsb_version_sync; print('  lsb_version_sync at:', lsb_version_sync.__file__)" 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -eq 0) { OK "lsb_version_sync import ok" } else { ER "lsb_version_sync still not importable" }

try {
    $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
    OK ("ollama models loaded: {0}" -f $tags.models.Count)
    foreach ($m in $tags.models) { Write-Host ("        {0}" -f $m.name) }
} catch { NO "ollama not reachable" }
Write-Host ""

Section "setup complete"
Write-Host "  log: $LogPath"
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Cyan
Stop-Transcript | Out-Null
if ($Host.Name -eq 'ConsoleHost') { [void][System.Console]::ReadKey($true) }
