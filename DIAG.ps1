# DIAG.ps1 - read-only diagnostic. No mutations.
#
# Answers: which prerequisites are installed, which services/bridges are
# already up, and what would change if we ran RUN.ps1. Logs to DIAG.log.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'DIAG.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($msg) { Write-Host "=== $msg ===" -ForegroundColor Green }
function OK($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function NO($msg) { Write-Host "  [--] $msg" -ForegroundColor Yellow }
function ER($msg) { Write-Host "  [ER] $msg" -ForegroundColor Red }

Section "live-box diagnostic"
Write-Host "  RepoRoot: $RepoRoot"
Write-Host "  Date    : $(Get-Date)"
Write-Host ""

# 1. Python
Section "python"
foreach ($exe in @('python','python3','py')) {
    $c = Get-Command $exe -ErrorAction SilentlyContinue
    if ($c) {
        $ver = & $c.Source -V 2>&1
        OK ("{0} -> {1} ({2})" -f $exe, $c.Source, $ver)
    } else {
        NO "$exe not on PATH"
    }
}
Write-Host ""

# 2. Git
Section "git"
$g = Get-Command git -ErrorAction SilentlyContinue
if ($g) { OK ("git -> {0}" -f $g.Source); OK ("version -> {0}" -f (& git --version)) } else { NO "git not on PATH" }
Write-Host ""

# 3. Ollama
Section "ollama"
$o = Get-Command ollama -ErrorAction SilentlyContinue
if ($o) {
    OK ("ollama -> {0}" -f $o.Source)
    try {
        $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
        OK ("daemon up; models loaded: {0}" -f ($tags.models.Count))
        foreach ($m in $tags.models) { Write-Host ("        {0} ({1} MB)" -f $m.name, [math]::Round($m.size/1MB)) }
    } catch { NO "daemon not responding on 127.0.0.1:11434" }
} else { NO "ollama not on PATH" }
Write-Host ""

# 4. MariaDB / MySQL
Section "database"
$mysql = Get-Command mysql -ErrorAction SilentlyContinue
if ($mysql) { OK ("mysql client -> {0}" -f $mysql.Source) } else { NO "mysql not on PATH" }
$svc = Get-Service -Name 'MariaDB*','MySQL*' -ErrorAction SilentlyContinue
foreach ($s in $svc) { OK ("service '{0}' -> {1}" -f $s.Name, $s.Status) }
if (-not $svc) { NO "no MariaDB/MySQL service found" }
Write-Host ""

# 5. Existing FFXI layout
Section "FFXI layout"
foreach ($d in 'F:\ffxi','F:\ffxi\server','F:\ffxi\ashita','F:\ffxi\client','F:\ffxi\deploy','F:\ffxi\mariadb','F:\ffxi\server\settings','F:\ffxi\server\settings\login.lua') {
    if (Test-Path $d) { OK $d } else { NO "$d - missing" }
}
Write-Host ""

# 6. LSB processes
Section "LSB processes"
$procs = Get-Process | Where-Object { $_.Name -match 'map_server|login_server|search_server|connect_server' }
if ($procs) { foreach ($p in $procs) { OK ("{0} pid={1}" -f $p.Name, $p.Id) } } else { NO "no LSB processes running" }
Write-Host ""

# 7. Bridge ports
Section "bridge ports"
foreach ($port in 27115, 27116, 54230, 54001, 54002, 54230) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $hit = $ar.AsyncWaitHandle.WaitOne(500, $false) -and $c.Connected
        if ($hit) { OK ("127.0.0.1:{0} listening" -f $port) } else { NO ("127.0.0.1:{0} closed" -f $port) }
    } finally { $c.Close() }
}
Write-Host ""

# 8. login.lua version / VER_LOCK
Section "login.lua (VER_LOCK + CLIENT_VER)"
$lua = 'F:\ffxi\server\settings\login.lua'
if (Test-Path $lua) {
    $txt = Get-Content $lua -Raw
    foreach ($field in 'VER_LOCK','CLIENT_VER') {
        if ($txt -match "(?m)^\s*$field\s*=\s*([^,\s]+)") { OK ("{0} = {1}" -f $field, $Matches[1]) }
        else { NO ("{0} not found in login.lua" -f $field) }
    }
} else { ER "login.lua not found at $lua" }
Write-Host ""

# 9. chharbot package on Python
Section "chharbot python package"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { $py = Get-Command py      -ErrorAction SilentlyContinue }
if ($py) {
    & $py.Source -c "import chharbot; print('  installed at:', chharbot.__file__)" 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { NO "chharbot not installed" }
} else { NO "no python to test" }
Write-Host ""

# 10. pyproject presence (what RUN.ps1 would pip install)
Section "repo pyproject files"
foreach ($p in 'chharbot\pyproject.toml','lsb_version_sync\pyproject.toml','sidecar\pyproject.toml') {
    $f = Join-Path $RepoRoot $p
    if (Test-Path $f) { OK $p } else { NO "$p missing" }
}
Write-Host ""

Section "diagnostic complete"
Write-Host "  log: $LogPath"
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Cyan
Stop-Transcript | Out-Null
if ($Host.Name -eq 'ConsoleHost') { [void][System.Console]::ReadKey($true) }
