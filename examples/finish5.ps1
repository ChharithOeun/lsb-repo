# finish5.ps1 - same CWD / staging as finish4 but WITHOUT --hide, and with
# stdout/stderr redirected to a capture file so we can read every line xiloader
# prints after auth. finish4 proved xiloader 2.1.1 launches with window title
# "FINAL FANTASY XI" but the process exits and no FFXiMain.dll ever loads in
# any process - meaning the chain into the game isn't happening. This run will
# show us the exact print line where xiloader gives up.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\finish5.ps1

$ErrorActionPreference = 'Continue'

$XiLoaderSrc = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$GameDir     = 'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI'
$XiLoaderDst = Join-Path $GameDir 'xiloader.exe'
$StdoutLog   = 'F:\ffxi\deploy\finish5.xiloader-stdout.log'
$StderrLog   = 'F:\ffxi\deploy\finish5.xiloader-stderr.log'
$LogPath     = 'F:\ffxi\deploy\finish5.log'

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== finish5 start ===" 'Green'

# Binary check.
$f = Get-Item -LiteralPath $XiLoaderSrc
$md5 = (Get-FileHash -Algorithm MD5 -LiteralPath $XiLoaderSrc).Hash
Step ("xiloader source : {0}" -f $XiLoaderSrc)
Step ("    size        : {0:N0} bytes" -f $f.Length)
Step ("    MD5         : {0}" -f $md5)
if ($md5 -ieq '44FE5F23BF76E4E847946B5B76F1E061') {
    Step "    >>> binary IS xiloader 2.1.1" 'Green'
} else {
    Step "    >>> WRONG BINARY" 'Red'
    Stop-Transcript | Out-Null
    exit 1
}

# Clean.
Step "--- cleaning up previous xiloader/pol processes ---"
Get-Process pol, xiloader -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_ | Stop-Process -Force } catch {}
}
Start-Sleep -Seconds 1

# Stage xiloader next to FFXiMain.dll.
Copy-Item -LiteralPath $XiLoaderSrc -Destination $XiLoaderDst -Force
Step ("staged xiloader at {0}" -f $XiLoaderDst) 'Green'

# Clear old capture logs.
Remove-Item -LiteralPath $StdoutLog, $StderrLog -ErrorAction SilentlyContinue

$xiArgs = @(
    '--server',   '127.0.0.1',
    '--user',     'GUESTCL1',
    '--password', 'guestpass',
    '--hairpin'
    # NO --hide this time - we want to see the output
)

Step "--- launching xiloader.exe with stdout/stderr capture ---"
Step ("argv: {0} {1}" -f $XiLoaderDst, ($xiArgs -join ' '))

$xi = Start-Process -FilePath $XiLoaderDst -ArgumentList $xiArgs `
        -WorkingDirectory $GameDir -PassThru `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError  $StderrLog

Step ("xiloader PID: {0}" -f $xi.Id)

# Give it plenty of time to auth AND attempt chain-load.
for ($i = 1; $i -le 6; $i++) {
    Start-Sleep -Seconds 5
    $alive = Get-Process -Id $xi.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        Step ("  ..{0}s xiloader has EXITED" -f ($i*5)) 'Yellow'
        break
    }
    Step ("  ..{0}s xiloader alive pid={1} title='{2}'" -f ($i*5), $alive.Id, $alive.MainWindowTitle)
    $mods = try { $alive.Modules | Where-Object { $_.ModuleName -ieq 'FFXiMain.dll' } } catch { $null }
    if ($mods) {
        Step "    !!! FFXiMain.dll is now loaded in xiloader process - game is running" 'Green'
    }
}

Step "--- xiloader stdout capture ---" 'Green'
if (Test-Path $StdoutLog) {
    Get-Content -LiteralPath $StdoutLog | ForEach-Object { Step ("  [out] {0}" -f $_) 'Gray' }
} else {
    Step "  (no stdout file)" 'Yellow'
}

Step "--- xiloader stderr capture ---" 'Green'
if (Test-Path $StderrLog) {
    Get-Content -LiteralPath $StderrLog | ForEach-Object { Step ("  [err] {0}" -f $_) 'Red' }
} else {
    Step "  (no stderr file)" 'Yellow'
}

# Final snapshot.
Step "--- final: processes named pol/xiloader/ffxi ---"
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -imatch '^(pol|xiloader|ffxi)' } |
    ForEach-Object {
        Step ("  pid={0,6} name={1,-14} title='{2}' path={3}" -f $_.Id, $_.ProcessName, $_.MainWindowTitle, $_.Path) 'Green'
    }

Step "--- final: processes with FFXiMain.dll loaded ---"
$loaded = @()
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $m = $_.Modules | Where-Object { $_.ModuleName -ieq 'FFXiMain.dll' }
        if ($m) { $loaded += $_ }
    } catch {}
}
if ($loaded) {
    foreach ($g in $loaded) {
        Step ("  pid={0,6} name={1,-14} title='{2}'" -f $g.Id, $g.ProcessName, $g.MainWindowTitle) 'Green'
    }
} else {
    Step "  (none)" 'Yellow'
}

Step ("xiloader final ExitCode: {0}" -f $xi.ExitCode)
Step "=== finish5 complete ===" 'Green'
Stop-Transcript | Out-Null
