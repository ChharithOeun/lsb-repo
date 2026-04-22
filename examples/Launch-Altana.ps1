# Launch-Altana.ps1
# PowerShell sibling of Launch-Altana.bat with a few extra niceties:
#   - Detects whether the spawned retail pol.exe came up
#   - Logs everything to F:\ffxi\deploy\altana-launch.log
#   - Returns a non-zero exit code on failure so it composes well in
#     larger orchestration scripts
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Launch-Altana.ps1
# Optional:
#   -Server 127.0.0.1  -User GUESTCL1  -Pass guestpass  -Profile 'Private Server'
#   -NoHide            (show xiloader console)
#   -SkipAshita        (only fire xiloader, skip launching Ashita)

param(
    [string] $XiLoader = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe',
    [string] $Ashita   = 'F:\ffxi\Ashita\ashita.exe',
    [string] $Profile  = 'Private Server',
    [string] $Server   = '127.0.0.1',
    [string] $User     = 'GUESTCL1',
    [string] $Pass     = 'guestpass',
    [switch] $NoHide,
    [switch] $SkipAshita
)

$ErrorActionPreference = 'Stop'
$LogPath = 'F:\ffxi\deploy\altana-launch.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($msg, $color = 'Cyan') { Write-Host $msg -ForegroundColor $color }

Step "=== Altana launcher ===" 'Cyan'
Step "xiloader: $XiLoader"
Step "ashita  : $Ashita"
Step "profile : $Profile"
Step "server  : $Server   user: $User"

if (-not (Test-Path $XiLoader)) { throw "xiloader not found: $XiLoader" }
if (-not $SkipAshita -and -not (Test-Path $Ashita)) { throw "ashita.exe not found: $Ashita" }

# Build xiloader args
$xiArgs = @('--server', $Server, '--user', $User, '--password', $Pass, '--hairpin')
if (-not $NoHide) { $xiArgs += '--hide' }

# Pre-launch: count current pol.exe processes so we can spot the new one.
$beforePids = @(Get-Process -Name 'pol' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

Step "Spawning xiloader ..."
$xi = Start-Process -FilePath $XiLoader -ArgumentList $xiArgs -PassThru
Step ("xiloader PID: {0}" -f $xi.Id)

# Wait briefly for xiloader to do the handshake and spawn the retail pol.exe
Start-Sleep -Milliseconds 1500

$afterPids = @(Get-Process -Name 'pol' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($afterPids | Where-Object { $beforePids -notcontains $_ -and $_ -ne $xi.Id })
if ($newPids.Count -gt 0) {
    Step ("Detected new pol.exe child PID(s): {0}" -f ($newPids -join ', ')) 'Green'
} else {
    Step "No new pol.exe child detected yet — Ashita will pick it up if/when it spawns." 'Yellow'
}

if ($SkipAshita) {
    Step "SkipAshita set — leaving xiloader running and exiting." 'Yellow'
    Stop-Transcript | Out-Null
    exit 0
}

Step "Launching Ashita ..."
& $Ashita --boot $Profile

Step "Done."
Stop-Transcript | Out-Null
