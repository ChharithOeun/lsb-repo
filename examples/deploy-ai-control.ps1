# deploy-ai-control.ps1 - install the two AI control bridges and their MCPs
# on the live Windows box. Run once after pulling the repo update; it is
# idempotent. Does NOT restart the LSB server; does NOT auto-load the Ashita
# addon (that's a /addon load ai_bridge from in-game).
#
# Layout on the live box after this runs:
#   F:\ffxi\Ashita\addons\ai_bridge\            - the Lua addon
#   F:\ffxi\deploy\mcp\ffxi_client\              - MCP for the client bridge
#   F:\ffxi\deploy\mcp\ffxi_admin\               - MCP for the admin bridge
#   F:\ffxi\deploy\sidecar\lsb_admin_api\        - HTTP sidecar + stdin pump
#   F:\ffxi\deploy\.lsb_admin_token              - shared secret (generated)
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\deploy-ai-control.ps1

param(
    [string]$RepoRoot  = 'F:\ffxi\deploy\repo',
    [string]$AshitaDir = 'F:\ffxi\Ashita',
    [string]$DeployDir = 'F:\ffxi\deploy',
    [switch]$SkipPipInstall
)

$ErrorActionPreference = 'Continue'
$LogPath = Join-Path $DeployDir 'deploy-ai-control.log'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Step "=== deploy-ai-control start ===" 'Green'
Step ("  repo root  : {0}" -f $RepoRoot)
Step ("  ashita dir : {0}" -f $AshitaDir)
Step ("  deploy dir : {0}" -f $DeployDir)

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Step "  ERROR: repo root does not exist" 'Red'
    Stop-Transcript | Out-Null; exit 1
}

function MirrorDir([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) {
        Step ("    skip (no source): {0}" -f $src) 'Yellow'
        return
    }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Step ("    {0}  -->  {1}" -f $src, $dst) 'Green'
}

# 1. Ashita addon.
Step "--- installing addons/ai_bridge ---"
MirrorDir (Join-Path $RepoRoot 'addons\ai_bridge') (Join-Path $AshitaDir 'addons\ai_bridge')

# 2. MCPs + sidecar.
Step "--- installing MCPs and sidecar ---"
MirrorDir (Join-Path $RepoRoot 'mcp\ffxi_client')           (Join-Path $DeployDir 'mcp\ffxi_client')
MirrorDir (Join-Path $RepoRoot 'mcp\ffxi_admin')            (Join-Path $DeployDir 'mcp\ffxi_admin')
MirrorDir (Join-Path $RepoRoot 'sidecar\lsb_admin_api')     (Join-Path $DeployDir 'sidecar\lsb_admin_api')
Copy-Item -Path (Join-Path $RepoRoot 'mcp\mcp.example.json') `
          -Destination (Join-Path $DeployDir 'mcp\mcp.example.json') -Force -ErrorAction SilentlyContinue

# 3. Shared admin token.
$tokPath = Join-Path $DeployDir '.lsb_admin_token'
if (-not (Test-Path -LiteralPath $tokPath)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $tok = [Convert]::ToBase64String($bytes).TrimEnd('=')
    Set-Content -LiteralPath $tokPath -Value $tok -NoNewline -Encoding ASCII
    Step ("    generated {0}" -f $tokPath) 'Green'
} else {
    Step ("    token file already exists: {0}" -f $tokPath) 'Yellow'
}

# 4. Python deps (optional).
if (-not $SkipPipInstall) {
    Step "--- pip install fastmcp httpx fastapi uvicorn pymysql ---"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        & $py.Source -m pip install --quiet fastmcp httpx fastapi uvicorn pymysql
        if ($LASTEXITCODE -eq 0) {
            Step "    pip install OK" 'Green'
        } else {
            Step ("    pip install returned {0} (you may need to install manually)" -f $LASTEXITCODE) 'Yellow'
        }
    } else {
        Step "    python not on PATH - skipping pip install" 'Yellow'
    }
}

Step "--- next steps ---" 'Green'
Step "    1. in Ashita, run:   /addon load ai_bridge"
Step "    2. start the sidecar (optional, only if you want admin control):"
Step "         python F:\ffxi\deploy\sidecar\lsb_admin_api\map_server_stdin_pump.py F:\ffxi\server\map_server.exe"
Step "         python F:\ffxi\deploy\sidecar\lsb_admin_api\server.py"
Step "    3. merge F:\ffxi\deploy\mcp\mcp.example.json into your Claude config"
Step "=== deploy-ai-control complete ===" 'Green'

Stop-Transcript | Out-Null
