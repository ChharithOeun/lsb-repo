# diag-final.ps1 - post-finish4 state snapshot.
# Captures: xiloader PID 4196 alive? Any process with FFXiMain.dll loaded?
# Any top-level window with "FINAL FANTASY" title? Running processes named
# pol/xiloader/ffxi/polboot. Also: is the game still auth'd on the server
# (netstat 51220 = lobby, 54230 = zone).

$ErrorActionPreference = 'Continue'
$LogPath = 'F:\ffxi\deploy\diag-final.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== diag-final start ===" 'Green'
Step ("time: {0}" -f (Get-Date))

# 1. PID 4196 (the xiloader from finish4).
Step "--- xiloader PID 4196 status ---"
$p = Get-Process -Id 4196 -ErrorAction SilentlyContinue
if ($p) {
    Step ("  ALIVE: {0} ({1})  title='{2}'" -f $p.Id, $p.ProcessName, $p.MainWindowTitle) 'Green'
} else {
    Step "  EXITED (pid 4196 no longer running)" 'Yellow'
}

# 2. Every pol/xiloader/ffxi/polboot process right now.
Step "--- processes named pol/xiloader/ffxi/polboot ---"
$found = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -imatch '^(pol|xiloader|ffxi|polboot|ashita)' }
if ($found) {
    foreach ($x in $found) {
        Step ("  pid={0,6} name={1,-14} title='{2}' path={3}" -f $x.Id, $x.ProcessName, $x.MainWindowTitle, $x.Path) 'Green'
    }
} else {
    Step "  (none)" 'Yellow'
}

# 3. Any process with FFXiMain.dll loaded = the retail client.
Step "--- processes with FFXiMain.dll loaded ---"
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

# 4. Top-level windows with FINAL FANTASY / POL / XI title.
Step "--- windows with 'FINAL FANTASY' / 'PlayOnline' / 'XI' title ---"
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -match '(?i)final fantasy|playonline|^FFXI' } |
    ForEach-Object {
        Step ("  pid={0,6} name={1,-14} title='{2}'" -f $_.Id, $_.ProcessName, $_.MainWindowTitle) 'Green'
    }

# 5. LSB server listening ports.
Step "--- LSB netstat (25280 login, 51220 lobby, 54230 zone) ---"
$ports = 25280, 51220, 54230
$ns = netstat -ano 2>$null
foreach ($prt in $ports) {
    $lines = $ns | Select-String -Pattern (":{0}\b" -f $prt)
    if ($lines) {
        Step ("  port {0}:" -f $prt) 'Green'
        foreach ($ln in $lines) { Step ("    {0}" -f $ln.Line.Trim()) }
    } else {
        Step ("  port {0}: no matching socket" -f $prt) 'Yellow'
    }
}

Step "=== diag-final complete ===" 'Green'
Stop-Transcript | Out-Null
