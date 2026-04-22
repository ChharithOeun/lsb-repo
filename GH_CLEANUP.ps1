# GH_CLEANUP.ps1 - audit ChharithOeun's GitHub repos for any with malformed
# names (left over from the first GIT_INIT.ps1 run where GITHUB_REPO was
# parsed as a full URL). Deletes any repo whose name contains "://", "http",
# or control chars -- these cannot be legitimate repo names.
#
# PAT sourced from C:\Users\User\Chharbot\.env (same as GIT_INIT.ps1).
# PAT is redacted from the transcript; never printed. Auth header only.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'GH_CLEANUP.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($m) { Write-Host "=== $m ===" -ForegroundColor Green }
function W($m)       { Write-Host $m -ForegroundColor Yellow }
function Fail($m)    { Write-Host "FATAL: $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }

function Redact([string]$s, [string]$pat) {
    if (-not $pat) { return $s }
    return ($s -replace [regex]::Escape($pat), '***REDACTED***')
}

Section "GitHub repo audit + cleanup"
Write-Host ("  started : {0}" -f (Get-Date))

# 1. Parse PAT from .env
Section "1. load PAT"
$envPath = 'C:\Users\User\Chharbot\.env'
if (-not (Test-Path $envPath)) { Fail ".env not found at $envPath" }
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
$pat = $null
foreach ($k in 'GITHUB_PAT','GH_TOKEN','GITHUB_TOKEN','GH_PAT','GIT_PAT') {
    if ($envMap.ContainsKey($k) -and $envMap[$k]) { $pat = $envMap[$k]; break }
}
if (-not $pat) { Fail "no PAT found in .env" }
Write-Host "  PAT loaded (not printed)"

$headers = @{
    'Authorization' = "Bearer $pat"
    'Accept'        = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# 2. Resolve user
Section "2. resolve user"
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 15
    $ghUser = $me.login
    Write-Host ("  user : {0}" -f $ghUser)
} catch {
    Fail ("/user API failed: {0}" -f (Redact $_.Exception.Message $pat))
}

# 3. List all repos (paginated)
Section "3. list repos"
$all = @()
$page = 1
while ($true) {
    try {
        $batch = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner" -Headers $headers -TimeoutSec 20
    } catch {
        Fail ("/user/repos failed (page $page): {0}" -f (Redact $_.Exception.Message $pat))
    }
    if (-not $batch) { break }
    $all += $batch
    if ($batch.Count -lt 100) { break }
    $page++
    if ($page -gt 20) { W "stopping at page 20 (safety)"; break }
}
Write-Host ("  total repos owned by {0} : {1}" -f $ghUser, $all.Count)

# 4. Flag malformed repos
Section "4. scan for malformed names"
$bad = @()
foreach ($r in $all) {
    $name = $r.name
    # Unambiguous garbage: contains a URL or protocol fragment.
    if ($name -match '://' -or $name -match '^https?' -or $name -match '^github\.com') {
        $bad += $r
        continue
    }
    # Contains characters GitHub doesn't normally allow in repo names.
    # GitHub permits: alnum, hyphen, underscore, period. Anything else = suspicious.
    if ($name -match '[^A-Za-z0-9._\-]') {
        $bad += $r
    }
}

if ($bad.Count -eq 0) {
    Write-Host "  no malformed repos found - account is clean" -ForegroundColor Green
} else {
    Write-Host ("  found {0} malformed repo(s):" -f $bad.Count) -ForegroundColor Yellow
    foreach ($r in $bad) {
        Write-Host ("    - {0}  (created {1}, private={2}, pushed {3})" -f $r.full_name, $r.created_at, $r.private, $r.pushed_at)
    }
}

# 5. Delete malformed repos (only if all three criteria met: created today,
#    zero commits, and name matches pattern). We require multiple safety gates
#    because deletion is irreversible.
Section "5. delete (safety-gated)"
$deleted = 0
$today = (Get-Date).ToString('yyyy-MM-dd')
foreach ($r in $bad) {
    $createdDay = ([DateTime]$r.created_at).ToString('yyyy-MM-dd')
    $isEmpty = ($r.size -eq 0)
    $isNew   = ($createdDay -eq $today) -or ($createdDay -eq ((Get-Date).AddDays(-1).ToString('yyyy-MM-dd')))
    Write-Host ("  {0}: created={1}, sizeKB={2}, empty={3}, new={4}" -f $r.full_name, $createdDay, $r.size, $isEmpty, $isNew)
    if ($isEmpty -and $isNew) {
        Write-Host ("    -> DELETING (empty + just created)") -ForegroundColor Red
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$($r.full_name)" -Headers $headers -Method DELETE -TimeoutSec 15 | Out-Null
            Write-Host "    -> deleted OK" -ForegroundColor Green
            $deleted++
        } catch {
            Write-Host ("    -> delete failed: {0}" -f (Redact $_.Exception.Message $pat)) -ForegroundColor Yellow
        }
    } else {
        W "    -> SKIP (not empty or not recently created - too risky to auto-delete)"
    }
}

# 6. Verify healthy repo still there
Section "6. verify lsb-repo still exists"
try {
    $lsb = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghUser/lsb-repo" -Headers $headers -TimeoutSec 15
    Write-Host ("  lsb-repo : OK  (private={0}, pushed {1})" -f $lsb.private, $lsb.pushed_at) -ForegroundColor Green
} catch {
    W ("  lsb-repo check failed: {0}" -f (Redact $_.Exception.Message $pat))
}

Section "summary"
Write-Host ("  total repos : {0}" -f $all.Count)
Write-Host ("  malformed   : {0}" -f $bad.Count)
Write-Host ("  deleted     : {0}" -f $deleted)
Write-Host ("  finished    : {0}" -f (Get-Date))

Stop-Transcript | Out-Null

# Scrub PAT from transcript as defense in depth
if (Test-Path $LogPath) {
    $t = Get-Content -LiteralPath $LogPath -Raw
    $t = Redact $t $pat
    Set-Content -LiteralPath $LogPath -Value $t -Encoding UTF8
}

if ($Host.Name -eq 'ConsoleHost') {
    Write-Host "Press any key to close..." -ForegroundColor Cyan
    [void][System.Console]::ReadKey($true)
}
