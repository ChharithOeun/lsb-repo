# PUSH_AAR.ps1 - commits AAR/ + the smoke-test update from 2026-04-21 and pushes
# to origin. Re-sources the PAT from .env (same pattern as GIT_INIT.ps1), uses
# an ephemeral PAT-in-URL for the push, and scrubs the credential afterward.
#
# Safe to re-run. If nothing new to commit, exits cleanly.

$ErrorActionPreference = 'Continue'
$RepoRoot = $PSScriptRoot
$LogPath  = Join-Path $RepoRoot 'PUSH_AAR.log'
Start-Transcript -Path $LogPath -Force | Out-Null

function Section($m) { Write-Host "=== $m ===" -ForegroundColor Green }
function W($m)       { Write-Host $m -ForegroundColor Yellow }
function Fail($m)    { Write-Host "FATAL: $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }

function Redact([string]$s, [string]$pat) {
    if (-not $pat) { return $s }
    return ($s -replace [regex]::Escape($pat), '***REDACTED***')
}

Section 'PUSH_AAR - commit + push AAR and smoke-test update'
Write-Host ("  started : {0}" -f (Get-Date))
Set-Location -LiteralPath $RepoRoot

# 0. housekeeping: remove sandbox tmp artifacts that may have leaked in
Get-ChildItem -LiteralPath $RepoRoot -Filter '*.tmp' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^PUSH_AAR\.' } |
    ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force; Write-Host ("  removed stray: {0}" -f $_.Name) }
        catch { W ("  could not remove {0}: {1}" -f $_.Name, $_.Exception.Message) }
    }

# 1. load PAT
Section '1. load PAT'
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
if (-not $pat) { Fail 'no PAT found in .env' }
Write-Host '  PAT loaded (not printed)'

# 2. resolve GH user
Section '2. resolve user'
$headers = @{
    'Authorization' = "Bearer $pat"
    'Accept'        = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 15
    $ghUser = $me.login
    Write-Host ("  user : {0}" -f $ghUser)
} catch {
    Fail ("/user API failed: {0}" -f (Redact $_.Exception.Message $pat))
}

# 3. stage + commit
Section '3. stage + commit'
& git add AAR/ chharbot/bin/smoke-test.ps1 PUSH_AAR.ps1 PUSH_AAR.bat GH_CLEANUP.ps1 GH_CLEANUP.bat GH_CLEANUP.log 2>&1 | ForEach-Object { Redact $_ $pat }
$status = & git status --porcelain 2>&1
if (-not $status) {
    W '  nothing to commit; tree clean'
} else {
    Write-Host '  staged changes:'
    $status | ForEach-Object { Write-Host "    $_" }
    $msg = "chore(aar): LL-2026-04-21-001 + smoke-test ai_bridge tri-state + GH_CLEANUP"
    & git -c user.name=$ghUser -c user.email="$ghUser@users.noreply.github.com" commit -m $msg 2>&1 | ForEach-Object { Redact $_ $pat }
}

# 4. push with ephemeral PAT
Section '4. push'
$repoName = 'lsb-repo'
$remoteUrl = "https://${ghUser}:${pat}@github.com/${ghUser}/${repoName}.git"
& git push $remoteUrl HEAD:main 2>&1 | ForEach-Object {
    $line = Redact $_ $pat
    $line = $line -replace '(https://[^:/\s]+:)[^@\s]+@', '$1***REDACTED***@'
    $line
}
$pushExit = $LASTEXITCODE

# 5. confirm scrubbed origin
Section '5. scrub origin'
$cleanUrl = "https://github.com/${ghUser}/${repoName}.git"
& git remote set-url origin $cleanUrl 2>&1 | ForEach-Object { Redact $_ $pat }
$after = & git remote get-url origin 2>&1
Write-Host ("  origin : {0}" -f $after)

Section 'summary'
if ($pushExit -eq 0) {
    Write-Host '  push : OK' -ForegroundColor Green
} else {
    W ("  push : exit {0}" -f $pushExit)
}
Write-Host ("  finished : {0}" -f (Get-Date))

Stop-Transcript | Out-Null

# Scrub PAT from transcript
if (Test-Path $LogPath) {
    $t = Get-Content -LiteralPath $LogPath -Raw
    $t = Redact $t $pat
    $t = $t -replace '(https://[^:/\s]+:)[^@\s]+@', '$1***REDACTED***@'
    Set-Content -LiteralPath $LogPath -Value $t -Encoding UTF8
}

if ($Host.Name -eq 'ConsoleHost') {
    Write-Host 'Press any key to close...' -ForegroundColor Cyan
    [void][System.Console]::ReadKey($true)
}
