# finish4.ps1 - same as finish3 but adds --hide to auto-login (skip the
# interactive "Login / Create New Account" menu that finish3 hit).
# Also copies xiloader alongside FFXiMain.dll so it can chain-exec into
# the game if that's what it's waiting for.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\finish4.ps1

$ErrorActionPreference = 'Continue'

$XiLoaderSrc = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$GameDir     = 'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI'
$FFXiMain    = Join-Path $GameDir 'FFXiMain.dll'
$XiLoaderDst = Join-Path $GameDir 'xiloader.exe'   # xiloader copy that sits next to FFXiMain.dll

$LogPath  = 'F:\ffxi\deploy\finish4.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== finish4 start ==="

# Binary verification.
$f = Get-Item -LiteralPath $XiLoaderSrc
$md5 = (Get-FileHash -Algorithm MD5 -LiteralPath $XiLoaderSrc).Hash
Step ("xiloader source : {0}" -f $XiLoaderSrc)
Step ("    size        : {0:N0} bytes" -f $f.Length)
Step ("    modified    : {0}" -f $f.LastWriteTime)
Step ("    MD5         : {0}" -f $md5)
Step ("    expected    : 44FE5F23BF76E4E847946B5B76F1E061 (xiloader 2.1.1)")

if ($md5 -ieq '44FE5F23BF76E4E847946B5B76F1E061') {
    Step "    >>> binary IS xiloader 2.1.1" 'Green'
} else {
    Step "    >>> binary is NOT stock xiloader 2.1.1" 'Yellow'
}

Step ("game dir        : {0}" -f $GameDir)
Step ("FFXiMain.dll    : {0}" -f $FFXiMain)
if (-not (Test-Path $FFXiMain)) {
    Step "ERROR: FFXiMain.dll missing" 'Red'
    Stop-Transcript | Out-Null
    exit 1
}

# Kill any existing pol/xiloader from earlier runs.
Step "--- cleaning up previous pol.exe / xiloader processes ---"
Get-Process pol, xiloader -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Step ("killing pid={0} name={1} path={2}" -f $_.Id, $_.ProcessName, $_.Path)
        $_ | Stop-Process -Force
    } catch {
        Step ("  could not kill pid={0}: {1}" -f $_.Id, $_) 'Yellow'
    }
}
Start-Sleep -Seconds 1

# Copy xiloader next to FFXiMain.dll so it can find the game DLL when it
# tries to chain-exec. Some xiloader builds look for FFXiMain.dll relative
# to the xiloader binary path, not relative to CWD.
Step "--- staging xiloader next to FFXiMain.dll ---"
try {
    Copy-Item -LiteralPath $XiLoaderSrc -Destination $XiLoaderDst -Force
    Step ("copied -> {0}" -f $XiLoaderDst) 'Green'
} catch {
    Step ("  copy failed: {0}" -f $_) 'Red'
    Stop-Transcript | Out-Null
    exit 1
}

$xiArgs = @(
    '--server',   '127.0.0.1',
    '--user',     'GUESTCL1',
    '--password', 'guestpass',
    '--hairpin',
    '--hide'
)

Step "--- launching xiloader.exe (from game dir) with --hide ---"
Step ("argv: {0} {1}" -f $XiLoaderDst, ($xiArgs -join ' '))

$before = @(Get-Process -Name pol, xiloader -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol/xiloader PIDs before: [{0}]" -f ($before -join ','))

$xi = Start-Process -FilePath $XiLoaderDst -ArgumentList $xiArgs `
        -WorkingDirectory $GameDir -PassThru

Step ("xiloader PID: {0}" -f $xi.Id)

# Give it more time to auth + chain-exec.
Start-Sleep -Seconds 10

$after = @(Get-Process -Name pol, xiloader -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Step ("pol/xiloader PIDs after auth wait: [{0}]" -f ($after -join ','))
$newPids = $after | Where-Object { $before -notcontains $_ }
Step ("new PIDs: [{0}]" -f ($newPids -join ','))

# List all processes that look related.
Step "--- all processes named pol / xiloader / ffxi ---"
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -imatch '^(pol|xiloader|ffxi)' } |
    ForEach-Object {
        Step ("  pid={0,6} name={1,-12} path={2}" -f $_.Id, $_.ProcessName, $_.Path) 'Green'
    }

# Processes with FFXiMain.dll loaded = the game.
Step "--- processes with FFXiMain.dll loaded (== game running) ---"
$loaded = @()
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $mod = $_.Modules | Where-Object { $_.ModuleName -ieq 'FFXiMain.dll' }
        if ($mod) { $loaded += $_ }
    } catch {}
}
if ($loaded) {
    foreach ($p in $loaded) {
        Step ("  pid={0,6} name={1,-12} path={2}" -f $p.Id, $p.ProcessName, $p.Path) 'Green'
    }
} else {
    Step "  (none yet)" 'Yellow'
}

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

Step "=== finish4 complete -- check for game window ==="
Stop-Transcript | Out-Null
