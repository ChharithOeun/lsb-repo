# find-lsb.ps1 - hunt for the live LSB server install and print its version
# config so we can fix FFXI-3331 autonomously.
#
# Looks under F:\, C:\, D:\ for a login.lua that contains CLIENT_VER, and for
# the login_server.exe / map_server.exe binaries. Also searches for any
# custom settings/login.lua that overrides the default.

$ErrorActionPreference = 'Continue'
$LogPath = 'F:\ffxi\deploy\find-lsb.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Note($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Note "=== find-lsb start ===" 'Green'

$roots = @('F:\', 'C:\', 'D:\') | Where-Object { Test-Path $_ }

# 1. Find login.lua files (default + customized).
Note "--- scanning for login.lua ---"
$loginLuas = @()
foreach ($r in $roots) {
    Get-ChildItem -Path $r -Filter 'login.lua' -Recurse -ErrorAction SilentlyContinue -Force |
        Where-Object {
            $_.FullName -notmatch 'node_modules|\\.git\\|\\windows\\|AppData\\Roaming' -and
            $_.Length -lt 100000
        } |
        ForEach-Object {
            $loginLuas += $_.FullName
        }
}
foreach ($lf in $loginLuas) {
    Note ("  {0}" -f $lf) 'Green'
}

# 2. For each login.lua, check if it contains CLIENT_VER.
Note "--- inspecting each for CLIENT_VER / VER_LOCK ---"
foreach ($lf in $loginLuas) {
    try {
        $txt = Get-Content -LiteralPath $lf -Raw -ErrorAction Stop
        if ($txt -match 'CLIENT_VER|VER_LOCK') {
            Note ("### {0}" -f $lf) 'Yellow'
            $txt -split "`r?`n" | Where-Object {
                $_ -match 'CLIENT_VER|VER_LOCK|^xi\s*\.login'
            } | ForEach-Object { Note ("    {0}" -f $_.Trim()) }
        }
    } catch {}
}

# 3. Find login_server / map_server binaries.
Note "--- scanning for login_server.exe / map_server.exe ---"
foreach ($r in $roots) {
    Get-ChildItem -Path $r -Filter 'login_server.exe' -Recurse -ErrorAction SilentlyContinue -Force |
        ForEach-Object { Note ("  login_server: {0}" -f $_.FullName) 'Green' }
    Get-ChildItem -Path $r -Filter 'map_server.exe' -Recurse -ErrorAction SilentlyContinue -Force |
        ForEach-Object { Note ("  map_server  : {0}" -f $_.FullName) 'Green' }
}

# 4. Running LSB processes right now.
Note "--- running LSB processes ---"
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -imatch 'login_server|map_server|search_server|connect_server' } |
    ForEach-Object {
        Note ("  pid={0,6} name={1,-16} path={2}" -f $_.Id, $_.ProcessName, $_.Path) 'Green'
    }

# 5. Port listeners - identify which process owns LSB ports.
Note "--- listeners on LSB-ish ports (54230, 54231, 54001, 25280, 51220) ---"
$ports = 54230, 54231, 54001, 25280, 51220
$ns = netstat -ano 2>$null
foreach ($prt in $ports) {
    $ns | Select-String -Pattern (":{0}\s" -f $prt) | ForEach-Object {
        Note ("  port {0}: {1}" -f $prt, $_.Line.Trim())
    }
}

Note "=== find-lsb complete ===" 'Green'
Stop-Transcript | Out-Null
