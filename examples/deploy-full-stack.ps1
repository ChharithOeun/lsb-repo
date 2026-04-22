# deploy-full-stack.ps1 - one-button install/repair for the Chharbot FFXI stack.
#
# Stages, in order:
#   1. Pre-flight   - python, pip, psutil available; tokens generated; ports free
#   2. AI bridges   - Ashita ai_bridge addon staged; sidecar installed
#   3. Version sync - pip install -e lsb_version_sync; scheduled task registered
#   4. chharbot     - pip install -e chharbot; sanity check
#   5. 3331 fix     - run patch-ver-lock (optional via -FixVerLock) OR version_sync
#                     (optional via -RunVersionSync) to get past the version-lock
#                     handshake
#   6. Smoke test   - hit the sidecar /health, call version_sync/status, print
#                     a one-screen summary
#
# Safe to re-run. Every mutating step is idempotent; every one-time step
# checks whether the thing is already in place before doing it again.
#
# Examples:
#   # Cold install + get to character select
#   .\deploy-full-stack.ps1 -RepoRoot F:\ffxi\deploy\repo -FixVerLock
#
#   # Existing install; just re-sync login.lua against retail
#   .\deploy-full-stack.ps1 -RepoRoot F:\ffxi\deploy\repo -RunVersionSync
#
#   # Dry-run - show what would happen, make no changes
#   .\deploy-full-stack.ps1 -RepoRoot F:\ffxi\deploy\repo -DryRun

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [string]$AshitaRoot     = 'F:\ffxi\Ashita',
    [string]$LsbServerRoot  = 'F:\ffxi\server',
    [string]$DeployRoot     = 'F:\ffxi\deploy',
    [string]$LoginLua       = '',   # default: <LsbServerRoot>\settings\login.lua

    [switch]$FixVerLock,            # run patch-ver-lock.ps1 to disable VER_LOCK
    [switch]$RunVersionSync,        # run lsb_version_sync (auto-match retail)
    [switch]$RegisterScheduledTask, # register the task-scheduler entry
    [switch]$StartSidecar,          # start lsb_admin_api in a new window
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not $LoginLua) { $LoginLua = Join-Path $LsbServerRoot 'settings\login.lua' }

$LogRoot = Join-Path $DeployRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
$LogPath = Join-Path $LogRoot ("deploy-full-stack_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogPath -Force | Out-Null

function Say($msg, $color = 'Cyan') {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}

function Fail($msg) { Say "ERROR: $msg" 'Red'; Stop-Transcript | Out-Null; exit 1 }

function Run($desc, [scriptblock]$block) {
    Say "  -> $desc"
    if ($DryRun) { Say "     (dry-run; skipped)" 'DarkGray'; return }
    try { & $block } catch { Say ("     failed: {0}" -f $_.Exception.Message) 'Red'; throw }
}

Say "==============================================================" 'Green'
Say "  Chharbot FFXI stack deploy" 'Green'
Say ("  repo        : {0}" -f $RepoRoot)
Say ("  ashita      : {0}" -f $AshitaRoot)
Say ("  lsb server  : {0}" -f $LsbServerRoot)
Say ("  login.lua   : {0}" -f $LoginLua)
Say ("  dry-run     : {0}" -f $DryRun.IsPresent)
Say ("  log         : {0}" -f $LogPath)
Say "==============================================================" 'Green'

# ---------- 1. Pre-flight ---------------------------------------------------

Say "`n[1/6] Pre-flight" 'Yellow'

if (-not (Test-Path $RepoRoot)) { Fail "RepoRoot not found: $RepoRoot" }
if (-not (Test-Path $LsbServerRoot)) { Fail "LsbServerRoot not found: $LsbServerRoot" }

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { Fail "Python not on PATH. Install Python 3.10+ first." }
Say ("  python       : {0}" -f $python.Source)

# Generate tokens if missing.
$adminToken = Join-Path $DeployRoot '.lsb_admin_token'
$aiToken    = Join-Path $DeployRoot '.aibridge_token'
New-Item -ItemType Directory -Force -Path $DeployRoot | Out-Null

function New-Token() {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
}

if (-not (Test-Path $adminToken) -or -not (Get-Content -LiteralPath $adminToken -Raw).Trim()) {
    Run "generate admin token at $adminToken" {
        Set-Content -LiteralPath $adminToken -Value (New-Token) -Encoding ASCII -NoNewline
    }
} else { Say "  admin token  : already present at $adminToken" }

if (-not (Test-Path $aiToken) -or -not (Get-Content -LiteralPath $aiToken -Raw).Trim()) {
    Run "generate ai_bridge token at $aiToken" {
        Set-Content -LiteralPath $aiToken -Value (New-Token) -Encoding ASCII -NoNewline
    }
} else { Say "  ai_bridge tok: already present at $aiToken" }

# Port availability check.
foreach ($p in @(27115, 27116)) {
    $inUse = $null
    try { $inUse = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue } catch {}
    if ($inUse) { Say ("  port {0}    : already bound (will reuse)" -f $p) 'DarkYellow' }
    else        { Say ("  port {0}    : free" -f $p) }
}

# ---------- 2. AI bridges ---------------------------------------------------

Say "`n[2/6] AI bridges (ai_bridge addon + lsb_admin_api sidecar)" 'Yellow'

$addonSrc  = Join-Path $RepoRoot 'addons\ai_bridge'
$addonDest = Join-Path $AshitaRoot 'addons\ai_bridge'
if (Test-Path $addonSrc) {
    Run "stage ai_bridge addon -> $addonDest" {
        New-Item -ItemType Directory -Force -Path $addonDest | Out-Null
        Copy-Item -Path (Join-Path $addonSrc '*') -Destination $addonDest -Recurse -Force
    }
} else { Say "  skipped: $addonSrc not in repo" 'DarkGray' }

$sidecarSrc = Join-Path $RepoRoot 'sidecar\lsb_admin_api'
if (Test-Path $sidecarSrc) {
    Run "pip install fastapi/uvicorn/pymysql/psutil (quiet)" {
        & $python.Source -m pip install --quiet --upgrade fastapi uvicorn pymysql psutil | Out-Null
    }
    Run "stage sidecar at $sidecarSrc (runs from repo in-place)" {
        # no copy needed; we start it from the repo path.
    }
} else { Fail "sidecar source missing at $sidecarSrc" }

# ---------- 3. lsb_version_sync --------------------------------------------

Say "`n[3/6] lsb_version_sync (retail auto-match)" 'Yellow'

$vsyncPkg = Join-Path $RepoRoot 'lsb_version_sync'
if (-not (Test-Path $vsyncPkg)) { Fail "lsb_version_sync package missing at $vsyncPkg" }

Run "pip install -e lsb_version_sync" {
    & $python.Source -m pip install -e $vsyncPkg --quiet | Out-Null
}

if ($RegisterScheduledTask) {
    $regScript = Join-Path $vsyncPkg 'bin\register-scheduled-task.ps1'
    if (Test-Path $regScript) {
        Run "register scheduled task (boot + every 6h)" {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -RepoRoot $RepoRoot
        }
    } else { Say "  scheduled task script not found; skipping" 'DarkGray' }
}

# ---------- 4. chharbot -----------------------------------------------------

Say "`n[4/6] chharbot (local-model agent)" 'Yellow'

$chharbotPkg = Join-Path $RepoRoot 'chharbot'
if (-not (Test-Path $chharbotPkg)) { Fail "chharbot package missing at $chharbotPkg" }

Run "pip install -e chharbot" {
    & $python.Source -m pip install -e $chharbotPkg --quiet | Out-Null
}
Run "chharbot import smoke test" {
    & $python.Source -c "import chharbot; print('chharbot', chharbot.__version__)"
}

# ---------- 5. 3331 fix (VER_LOCK or version_sync) -------------------------

Say "`n[5/6] FFXI-3331 fix" 'Yellow'

if ($FixVerLock -and $RunVersionSync) {
    Fail "-FixVerLock and -RunVersionSync are mutually exclusive. Pick one."
}

if ($FixVerLock) {
    $patchScript = Join-Path $RepoRoot 'examples\patch-ver-lock.ps1'
    if (-not (Test-Path $patchScript)) { Fail "patch-ver-lock.ps1 missing at $patchScript" }
    Run "patch-ver-lock: VER_LOCK -> 0, bounce login_server" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $patchScript -LoginLua $LoginLua
    }
} elseif ($RunVersionSync) {
    Run "lsb_version_sync sync (auto-match retail CLIENT_VER)" {
        Push-Location $vsyncPkg
        try {
            & $python.Source -m lsb_version_sync sync
        } finally { Pop-Location }
    }
} else {
    Say "  (neither -FixVerLock nor -RunVersionSync specified; skipping)" 'DarkGray'
    Say "  re-run with -FixVerLock to disable version lock (fastest path)" 'DarkGray'
    Say "  or       -RunVersionSync to auto-match retail's CLIENT_VER" 'DarkGray'
}

# ---------- 6. Smoke test / status -----------------------------------------

Say "`n[6/6] Smoke test" 'Yellow'

if ($StartSidecar) {
    Run "start lsb_admin_api in a new window" {
        $env:LSB_ADMIN_TOKEN_FILE = $adminToken
        # cwd must be sidecar/, not sidecar/lsb_admin_api/, so Python can
        # resolve the `lsb_admin_api` package when uvicorn imports
        # `lsb_admin_api.server:app`.
        $sidecarParent = Split-Path $sidecarSrc -Parent
        Start-Process -FilePath $python.Source `
            -ArgumentList @('-m', 'uvicorn', 'lsb_admin_api.server:app',
                            '--host', '127.0.0.1', '--port', '27116') `
            -WorkingDirectory $sidecarParent `
            -WindowStyle Minimized
    }
    Start-Sleep -Seconds 2
}

Run "probe sidecar /health" {
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:27116/health' -TimeoutSec 3
        Say ("     health = {0}" -f ($h | ConvertTo-Json -Compress)) 'Green'
    } catch {
        Say "     (sidecar not running; start with -StartSidecar)" 'DarkYellow'
    }
}

Run "version_sync status (offline, no sidecar needed)" {
    Push-Location $vsyncPkg
    try {
        & $python.Source -m lsb_version_sync status
    } finally { Pop-Location }
}

# ---------- Summary ---------------------------------------------------------

Say "`n==============================================================" 'Green'
Say "  DEPLOY SUMMARY" 'Green'
Say "==============================================================" 'Green'
Say "  admin token    : $adminToken"
Say "  ai_bridge tok  : $aiToken"
Say "  log            : $LogPath"
Say ""
Say "  Next:" 'Cyan'
if (-not $FixVerLock -and -not $RunVersionSync) {
    Say "    - 3331 fix not yet applied. Re-run with -FixVerLock or -RunVersionSync."
}
if (-not $StartSidecar) {
    Say "    - Sidecar not auto-started. To start manually:"
    Say "        `$env:LSB_ADMIN_TOKEN_FILE='$adminToken'"
    Say "        cd '$sidecarSrc'; python -m uvicorn lsb_admin_api.server:app --host 127.0.0.1 --port 27116"
}
Say "    - Test chharbot: python -m chharbot --probe 'what is my HP?'"
Say "    - Launch game:   deploy\Launch-Altana.ps1"
Say ""

Stop-Transcript | Out-Null
