# patch-ver-lock.ps1 - fix FFXI-3331 by disabling LSB's strict client version
# lock, back up the original login.lua, then bounce login_server so the change
# takes effect. Optionally overrides CLIENT_VER to the current retail string if
# one is provided.
#
# This is the last remaining blocker between the working xiloader->FFXiMain
# chain (proved in finish5.ps1) and the character-select screen. LSB's
# F:\ffxi\server\settings\login.lua currently reads:
#     CLIENT_VER = '30260203_0',
#     VER_LOCK   = 2,
# VER_LOCK=2 is "greater-than-or-equal" but in practice a newer Steam retail
# client advertises a newer date-stamp than the server's and the comparator
# rejects it anyway. The safe, reversible private-server fix is VER_LOCK=0
# (accept any client). If you'd rather match the retail version exactly, run
# with -NewClientVer '<yyyymmdd_r>' and leave VER_LOCK at 2.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\patch-ver-lock.ps1
# or, to match a known retail version:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\patch-ver-lock.ps1 -NewClientVer '30260401_0'

param(
    [string]$LoginLua     = 'F:\ffxi\server\settings\login.lua',
    [string]$NewClientVer = '',       # blank = leave CLIENT_VER alone
    [int]   $NewVerLock   = 0,        # 0=disable check, 2=GE (retail-match mode)
    [switch]$NoRestart                # skip the login_server bounce
)

$ErrorActionPreference = 'Continue'
$LogPath = 'F:\ffxi\deploy\patch-ver-lock.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Note($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Note "=== patch-ver-lock start ===" 'Green'
Note ("  login.lua    : {0}" -f $LoginLua)
Note ("  NewClientVer : {0}" -f ($(if ($NewClientVer) { $NewClientVer } else { '(unchanged)' })))
Note ("  NewVerLock   : {0}" -f $NewVerLock)
Note ("  NoRestart    : {0}" -f $NoRestart.IsPresent)

if (-not (Test-Path -LiteralPath $LoginLua)) {
    Note "  ERROR: login.lua not found at the given path" 'Red'
    Stop-Transcript | Out-Null
    exit 1
}

# 1. Back up.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$LoginLua.ver-lock-bak.$stamp"
Copy-Item -LiteralPath $LoginLua -Destination $bak -Force
Note ("  backed up to {0}" -f $bak) 'Green'

# 2. Patch.
$txt = Get-Content -LiteralPath $LoginLua -Raw
$orig = $txt

# VER_LOCK - allow whitespace around the `=`.
if ($txt -match '(?m)^\s*VER_LOCK\s*=\s*\d+\s*,') {
    $txt = [regex]::Replace(
        $txt,
        '(?m)^(\s*VER_LOCK\s*=\s*)\d+(\s*,.*)$',
        ('${1}' + $NewVerLock + '${2}')
    )
    Note ("  patched VER_LOCK -> {0}" -f $NewVerLock) 'Yellow'
} else {
    Note "  WARNING: VER_LOCK line not found; appending" 'Yellow'
    $txt = $txt.TrimEnd() + "`r`nVER_LOCK = $NewVerLock,`r`n"
}

# CLIENT_VER - only if requested.
if ($NewClientVer -ne '') {
    if ($txt -match "(?m)^\s*CLIENT_VER\s*=\s*'[^']*'\s*,") {
        $txt = [regex]::Replace(
            $txt,
            "(?m)^(\s*CLIENT_VER\s*=\s*')[^']*('\s*,.*)$",
            ('${1}' + $NewClientVer + '${2}')
        )
        Note ("  patched CLIENT_VER -> {0}" -f $NewClientVer) 'Yellow'
    } else {
        Note "  WARNING: CLIENT_VER line not found; appending" 'Yellow'
        $txt = $txt.TrimEnd() + "`r`nCLIENT_VER = '$NewClientVer',`r`n"
    }
}

if ($txt -eq $orig) {
    Note "  (no changes written)" 'Yellow'
} else {
    Set-Content -LiteralPath $LoginLua -Value $txt -Encoding UTF8 -NoNewline:$false
    Note "  wrote patched login.lua" 'Green'
}

# 3. Show the patched block back.
Note "--- patched login.lua relevant lines ---"
Get-Content -LiteralPath $LoginLua | Where-Object {
    $_ -match 'CLIENT_VER|VER_LOCK'
} | ForEach-Object { Note ("    {0}" -f $_.Trim()) }

# 4. Bounce login_server unless told not to.
if ($NoRestart) {
    Note "--- skipping login_server restart (per -NoRestart) ---"
} else {
    Note "--- restarting login_server ---"
    $proc = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -ieq 'login_server' } |
        Select-Object -First 1
    if ($proc) {
        $path = $proc.Path
        $cwd = Split-Path $path -Parent
        Note ("  found login_server pid={0} path={1}" -f $proc.Id, $path)
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {}
        Start-Sleep -Seconds 2
        # Confirm dead.
        $still = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($still) {
            Note "  WARNING: login_server still alive after Stop-Process" 'Red'
        } else {
            Note "  login_server stopped" 'Green'
        }
        # Respawn.
        $new = Start-Process -FilePath $path -WorkingDirectory $cwd -PassThru -WindowStyle Minimized
        Note ("  respawned login_server pid={0}" -f $new.Id) 'Green'
        Start-Sleep -Seconds 2
    } else {
        Note "  login_server.exe not currently running; nothing to restart" 'Yellow'
    }
}

# 5. Final listener check.
Note "--- listeners on login-auth port 54231 ---"
$ns = netstat -ano 2>$null
$ns | Select-String -Pattern ':54231\s' | ForEach-Object {
    Note ("  {0}" -f $_.Line.Trim())
}

Note "=== patch-ver-lock complete ===" 'Green'
Stop-Transcript | Out-Null
