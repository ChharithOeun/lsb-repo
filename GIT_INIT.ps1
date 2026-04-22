# GIT_INIT.ps1 - one-shot: init git repo in F:\ffxi\lsb-repo, commit
# everything, set up GitHub remote using the PAT from .env, and push.
#
# Security notes:
#   * PAT never logged to the transcript (we rewrite the line that would
#     have leaked it).
#   * PAT is used in the remote URL only during `git push`. After the
#     push succeeds we reset origin back to a URL without the token so
#     .git/config is clean and can be safely shared.
#   * If the repo doesn't exist on GitHub yet we create it via the API
#     using the PAT as a Bearer header. Repo is created PRIVATE by default.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'GIT_INIT.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($m) { Write-Host "=== $m ===" -ForegroundColor Green }
function W($m)       { Write-Host $m -ForegroundColor Yellow }
function Fail($m)    { Write-Host "FATAL: $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }

# Redacts the PAT anywhere it would appear in transcripts/output.
function Redact([string]$s, [string]$pat) {
    if (-not $pat) { return $s }
    return ($s -replace [regex]::Escape($pat), '***REDACTED***')
}

Section "git init + remote setup + push"
Write-Host ("  RepoRoot : {0}" -f $RepoRoot)
Write-Host ("  started  : {0}" -f (Get-Date))

# 1. Locate .env and parse it --------------------------------------------------
Section "1. locate .env"

# Helper: does this file contain a GitHub PAT key?
function HasPat([string]$path) {
    try {
        $txt = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        return ($txt -match '(?m)^\s*(GITHUB_PAT|GH_TOKEN|GITHUB_TOKEN|GH_PAT|GIT_PAT)\s*=\s*\S')
    } catch { return $false }
}

# Stage A: fast, known-location probes
$envCandidates = @(
    'C:\Users\User\Chharbot\.env',
    'F:\ffxi\deploy\.env',
    'F:\ffxi\.env',
    'F:\ffxi\lsb-repo\.env',
    'F:\ffxi\chharbot\.env',
    'F:\ffxi\sidecar\.env',
    'F:\ffxi\ai_bridge\.env',
    'F:\ffxi\lsb_admin_api\.env',
    'F:\ffxi\lsb_version_sync\.env',
    'F:\ffxi\control\.env',
    'F:\.env',
    (Join-Path $HOME '.env'),
    'C:\Users\User\.env',
    'C:\Users\User\Documents\.env',
    'C:\Users\User\OneDrive\.env',
    'C:\Users\User\Desktop\.env'
) | Where-Object { Test-Path $_ }

$envPath = $null
foreach ($c in $envCandidates) {
    if (HasPat $c) { $envPath = $c; break }
}
if (-not $envPath -and $envCandidates) { $envPath = $envCandidates[0] }

# Stage B: if nothing found, scan F:\ffxi and C:\Users\User for any .env with a PAT
if (-not $envPath) {
    Write-Host "  no .env in known spots, running recursive scan (F:\ffxi, C:\Users\User)..." -ForegroundColor Yellow
    $roots = @('F:\ffxi', 'C:\Users\User') | Where-Object { Test-Path $_ }
    foreach ($root in $roots) {
        try {
            $hits = Get-ChildItem -LiteralPath $root -Recurse -Force -File `
                -Include '.env','.env.*' -ErrorAction SilentlyContinue `
                -Depth 6
            foreach ($h in $hits) {
                if ($h.FullName -match '\\(\.git|node_modules|__pycache__|\.venv|venv|dist|build|AppData\\Local\\Packages)\\') { continue }
                if (HasPat $h.FullName) { $envPath = $h.FullName; break }
            }
            if ($envPath) { break }
        } catch { }
    }
}

if (-not $envPath) {
    Fail "no .env with a GitHub PAT found in F:\ffxi\ or C:\Users\User\ (scanned recursively). Please place a .env containing GITHUB_PAT=ghp_... in F:\ffxi\deploy\.env and re-run."
}
Write-Host ("  using .env: {0}" -f $envPath)

$envMap = @{}
Get-Content -LiteralPath $envPath | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { return }
    $k = $line.Substring(0, $eq).Trim()
    $v = $line.Substring($eq + 1).Trim().Trim("'", '"')
    $envMap[$k] = $v
}
Write-Host ("  parsed {0} entries (keys only): {1}" -f $envMap.Count, (($envMap.Keys | Sort-Object) -join ', '))

# 2. Pull out what we need -----------------------------------------------------
Section "2. extract PAT and repo target"
$pat = $null
foreach ($k in 'GITHUB_PAT','GH_TOKEN','GITHUB_TOKEN','GH_PAT','GIT_PAT') {
    if ($envMap.ContainsKey($k) -and $envMap[$k]) { $pat = $envMap[$k]; Write-Host "  PAT key  : $k"; break }
}
if (-not $pat) { Fail "no PAT found in .env (looked for GITHUB_PAT/GH_TOKEN/GITHUB_TOKEN/GH_PAT/GIT_PAT)" }

$ghUser = $null
foreach ($k in 'GITHUB_USER','GH_USER','GITHUB_USERNAME') {
    if ($envMap.ContainsKey($k) -and $envMap[$k]) { $ghUser = $envMap[$k]; break }
}
$ghRepoName = $null
foreach ($k in 'GITHUB_REPO','GH_REPO','REPO_NAME') {
    if ($envMap.ContainsKey($k) -and $envMap[$k]) { $ghRepoName = $envMap[$k]; break }
}

# Probe /user to get the username if we don't have it.
$headers = @{ 'Authorization' = "Bearer $pat"; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
if (-not $ghUser) {
    try {
        $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 10
        $ghUser = $me.login
        Write-Host ("  GH user  : {0} (from /user API)" -f $ghUser)
    } catch {
        Fail ("could not resolve GitHub user from PAT: {0}" -f (Redact $_.Exception.Message $pat))
    }
} else {
    Write-Host ("  GH user  : {0} (from .env)" -f $ghUser)
}

if (-not $ghRepoName) { $ghRepoName = 'lsb-repo' }
Write-Host ("  GH repo  : {0}/{1}" -f $ghUser, $ghRepoName)

$repoFullName = "$ghUser/$ghRepoName"
$remoteUrlPublic  = "https://github.com/$repoFullName.git"
$remoteUrlWithPat = "https://$($ghUser):$pat@github.com/$repoFullName.git"

# 3. Verify git is installed ---------------------------------------------------
Section "3. verify git"
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Fail "git not on PATH - install Git for Windows first" }
Write-Host ("  git      : {0}" -f $git.Source)
& git --version

# 4. Ensure the remote repo exists (create if missing) -------------------------
Section "4. ensure remote repo exists"
$remoteExists = $false
try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$repoFullName" -Headers $headers -TimeoutSec 10 | Out-Null
    $remoteExists = $true
    Write-Host ("  remote   : exists at {0}" -f $remoteUrlPublic) -ForegroundColor Green
} catch {
    $remoteExists = $false
    Write-Host "  remote   : does not exist, will create (private)" -ForegroundColor Yellow
}
if (-not $remoteExists) {
    $body = @{
        name = $ghRepoName
        private = $true
        description = 'LSB FFXI private-server Chharbot control stack (ai_bridge + sidecar + version-sync + chharbot)'
        auto_init = $false
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Headers $headers -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 15 | Out-Null
        Write-Host "  remote   : created OK" -ForegroundColor Green
    } catch {
        Fail ("repo create failed: {0}" -f (Redact $_.Exception.Message $pat))
    }
}

# 5. Init local repo if needed -------------------------------------------------
Section "5. local git init"
$dotGit = Join-Path $RepoRoot '.git'
if (-not (Test-Path $dotGit)) {
    Write-Host "  .git     : missing, running git init -b main"
    & git -C $RepoRoot init -b main
    if ($LASTEXITCODE -ne 0) { Fail "git init failed" }
} else {
    Write-Host "  .git     : already present"
    # Ensure branch is main
    & git -C $RepoRoot branch -M main 2>$null
}

# Identity (local, so we don't stomp global config)
if (-not (& git -C $RepoRoot config user.email)) {
    & git -C $RepoRoot config user.email "$ghUser@users.noreply.github.com"
}
if (-not (& git -C $RepoRoot config user.name)) {
    & git -C $RepoRoot config user.name $ghUser
}
Write-Host ("  user.name : {0}" -f (& git -C $RepoRoot config user.name))
Write-Host ("  user.email: {0}" -f (& git -C $RepoRoot config user.email))

# 6. Stage + commit ------------------------------------------------------------
Section "6. stage + commit"
& git -C $RepoRoot add -A
$statusOut = & git -C $RepoRoot status --short
if (-not $statusOut) {
    Write-Host "  nothing to commit (working tree clean)"
} else {
    $lines = @(
        'Initial commit: LSB Chharbot control stack',
        '',
        '* ai_bridge Ashita addon + MCP bridge',
        '* lsb_admin_api FastAPI sidecar (auth-fail-closed, per-endpoint RBAC)',
        '* lsb_version_sync retail auto-match (patch2.cfg primary, FFXiMain.dll fallback)',
        '* chharbot local-model agent (Ollama llama3.1:8b-instruct-q4_K_M)',
        '* Deploy/smoke/probe/sync/restart wrappers',
        '* Docs: SECURITY-REVIEW, AI-CONTROL-ARCHITECTURE, CHANGELOG',
        '',
        'FFXI-3331 version mismatch resolved via lsb_version_sync patching',
        "login.lua CLIENT_VER to match retail's latest patch2.cfg entry."
    )
    $msg = $lines -join [Environment]::NewLine
    & git -C $RepoRoot commit -m $msg
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }
}

# 7. Configure remote (token URL, for push) ------------------------------------
Section "7. configure origin (token URL - ephemeral)"
$existingOrigin = & git -C $RepoRoot remote get-url origin 2>$null
if ($existingOrigin) {
    & git -C $RepoRoot remote set-url origin $remoteUrlWithPat | Out-Null
} else {
    & git -C $RepoRoot remote add origin $remoteUrlWithPat | Out-Null
}
Write-Host "  origin   : configured with PAT (URL not logged)"

# 8. Push ----------------------------------------------------------------------
Section "8. push to origin main"
$pushOut = & git -C $RepoRoot push -u origin main 2>&1
$pushExit = $LASTEXITCODE
# Redact the PAT from output before printing
$pushOut | ForEach-Object { Write-Host (Redact $_ $pat) }
if ($pushExit -ne 0) {
    # Scrub remote before bailing so the PAT doesn't persist in .git/config.
    & git -C $RepoRoot remote set-url origin $remoteUrlPublic | Out-Null
    Fail "git push failed (exit $pushExit). Remote URL scrubbed."
}

# 9. Scrub the PAT out of origin ----------------------------------------------
Section "9. scrub PAT from origin URL"
& git -C $RepoRoot remote set-url origin $remoteUrlPublic | Out-Null
$finalOrigin = & git -C $RepoRoot remote get-url origin
Write-Host ("  origin   : {0}" -f $finalOrigin) -ForegroundColor Green

# 10. Verify -------------------------------------------------------------------
Section "10. verify"
& git -C $RepoRoot log --oneline -n 3
Write-Host ""
Write-Host ("  Repo URL : https://github.com/{0}" -f $repoFullName) -ForegroundColor Green
Write-Host ("  finished : {0}" -f (Get-Date))

Stop-Transcript | Out-Null

# Extra safety: redact PAT from the transcript file itself
if (Test-Path $LogPath) {
    $t = Get-Content -LiteralPath $LogPath -Raw
    $t = Redact $t $pat
    Set-Content -LiteralPath $LogPath -Value $t -Encoding UTF8
}

if ($Host.Name -eq 'ConsoleHost') {
    Write-Host "Press any key to close..." -ForegroundColor Cyan
    [void][System.Console]::ReadKey($true)
}
