# finish3.ps1 - run xiloader with CWD set to the retail FFXI folder that
# actually contains FFXiMain.dll. finish2 proved that xiloader launches and
# auths fine, but it was pointed at PlayOnlineViewer\ (which only has pol.exe),
# so the chain-exec into the game never finds FFXiMain.dll.
#
# The real FFXiMain.dll location (verified in finish2.log) is:
#   C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\FFXiMain.dll
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\finish3.ps1

$ErrorActionPreference = 'Continue'

$XiLoader = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'   # this IS xiloader 2.1.1
$GameDir  = 'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI'
$FFXiMain = Join-Path $GameDir 'FFXiMain.dll'

$LogPath  = 'F:\ffxi\deploy\finish3.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== finish3 start ==="
Step "xiloader path : $XiLoader"
Step "game dir      : $GameDir"
Step "ffximain.dll  : $FFXiMain"

if (-not (Test-Path $XiLoader)) {
    Step "ERROR: xiloader not found at $XiLoader" 'Red'
    Stop-Transcript | Out-Null
    exit 1
}
if (-not (Test-Path $GameDir)) {
    Step "ERROR: game dir not found: $GameDir" 'Red'
    Stop-Transcript | Out-Null
    exit 1
}
if (-not (Test-Path $FFXiMain)) {
    Step "ERROR: FFXiMain.dll not found in game dir" 'Red'
    Step "contents of $GameDir :" 'Yellow'
    Get-ChildItem -LiteralPath $GameDir | Select-Object Name, Length | Format-Table | Out-String | Write-Host
    Stop-Transcript | Out-Null
    exit 1
}

$fi = Get-Item -LiteralPath $FFXiMain
Step ("FFXiMain.dll OK -- size {0:N0} bytes, modified {1}" -f $fi.Length, $fi.LastWriteTime) 'Green'

# Kill any existing xiloader / pol.exe from earlier runs so we start clean.
Step "--- cleaning up previous pol.exe / xiloader processes ---"
$toKill = Get-Process pol -ErrorAction SilentlyContinue
if ($toKill) {
    foreach ($p in $toKill) {
        try {
            Step ("killing pol pid={0} path={1}" -f $p.Id, $p.Path)
            $p | Stop-Process -Force -ErrorAction Stop
        } catch {
            Step ("could not kill pid={0}: {1}" -f $p.Id, $_) 'Yellow'
        }
    }
    Start-Sleep -Seconds 1
}

$xiArgs = @(
    '--server',   '127.0.0.1',
    '--user',     'GUESTCL1',
    '--password', 'guestpass',
    '--hairpin'
)

Step "--- launching xiloader with CWD = $GameDir ---"
Step ("argv: {0} {1}" -f $XiLoader, ($xiArgs -join ' '))

$before = @(Get-Process pol -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol.exe PIDs before: [{0}]" -f ($before -join ','))

# Important: -WorkingDirectory sets CWD for the child process. This is what
# lets xiloader (and/or the chained game) find FFXiMain.dll alongside it.
$xi = Start-Process -FilePath $XiLoader -ArgumentList $xiArgs `
        -WorkingDirectory $GameDir -PassThru

Step ("xiloader PID: {0}" -f $xi.Id)

# Wait a bit for xiloader to auth and chain-exec.
Start-Sleep -Seconds 8

$after = @(Get-Process pol -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol.exe PIDs after auth wait: [{0}]" -f ($after -join ','))
$new = $after | Where-Object { $before -notcontains $_ }
Step ("new pol.exe PIDs: [{0}]" -f ($new -join ','))

# Check for FFXiMain-hosted processes (ffximain.dll gets loaded into the game
# process once chain-exec succeeds).
Step "--- processes with FFXiMain.dll loaded ---"
$loaded = Get-Process | Where-Object {
    try { $_.Modules | Where-Object { $_.ModuleName -ieq 'FFXiMain.dll' } } catch { $false }
}
if ($loaded) {
    foreach ($p in $loaded) {
        Step ("  pid={0} name={1} path={2}" -f $p.Id, $p.ProcessName, $p.Path) 'Green'
    }
} else {
    Step "  (none yet)" 'Yellow'
}

# xiloader status
$xiStill = Get-Process -Id $xi.Id -ErrorAction SilentlyContinue
if ($xiStill) {
    Step ("xiloader still running (pid={0})" -f $xi.Id) 'Green'
    try {
        $wt = $xiStill.MainWindowTitle
        if ($wt) { Step ("  window title: {0}" -f $wt) }
    } catch {}
} else {
    Step "xiloader exited" 'Yellow'
    Step ("  exit code: {0}" -f $xi.ExitCode)
}

Step "=== finish3 complete -- check the game window ==="
Stop-Transcript | Out-Null
