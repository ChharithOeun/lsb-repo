# publish.ps1 — commit & push the current repo state to GitHub.
#
# Idempotent: if there's nothing to commit, just prints that and exits 0.
# Tags the commit with a v7.1.0-style tag when a matching CHANGELOG
# header is the first in docs/CHANGELOG.md.
#
# Usage:
#   .\bin\publish.ps1                    # commit + push to current branch
#   .\bin\publish.ps1 -NoPush            # commit only
#   .\bin\publish.ps1 -Message 'custom'  # override auto-generated message
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$Message,
    [switch]$NoPush,
    [switch]$NoTag
)

$ErrorActionPreference = 'Stop'
Set-Location $RepoRoot

function Run($cmd, $argsList) {
    Write-Host "  > $cmd $($argsList -join ' ')" -ForegroundColor DarkGray
    & $cmd @argsList
    if ($LASTEXITCODE -ne 0) { throw "$cmd failed with exit $LASTEXITCODE" }
}

# 1. Detect the top of CHANGELOG so the commit + tag line up with the latest entry.
$changelog = Join-Path $RepoRoot 'docs\CHANGELOG.md'
$firstHeader = $null; $version = $null; $title = $null
if (Test-Path $changelog) {
    foreach ($line in Get-Content $changelog) {
        if ($line -match '^##\s+\[([^\]]+)\]\s+\u2014\s+\d{4}-\d{2}-\d{2}\s+\((.+)\)\s*$' -or
            $line -match '^##\s+\[([^\]]+)\]\s+-\s+\d{4}-\d{2}-\d{2}\s+\((.+)\)\s*$') {
            $version = $Matches[1]; $title = $Matches[2]; $firstHeader = $line; break
        }
    }
}
Write-Host "=== publish.ps1 ===" -ForegroundColor Green
Write-Host "  repo    : $RepoRoot"
if ($version) {
    Write-Host "  version : $version"
    Write-Host "  title   : $title"
}

# 2. Anything to commit?
$status = (& git status --porcelain 2>&1) -join "`n"
if (-not $status) {
    Write-Host "  nothing to commit - working tree clean." -ForegroundColor Yellow
    if (-not $NoPush) { Run 'git' @('push') }
    exit 0
}

Write-Host "  changes:" -ForegroundColor Cyan
$status -split "`n" | ForEach-Object { Write-Host "    $_" }

# 3. Commit.
if (-not $Message) {
    if ($version -and $title) {
        $Message = "release: $version ($title)"
    } else {
        $Message = "chore: snapshot $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
    }
}
Run 'git' @('add', '-A')
Run 'git' @('commit', '-m', $Message)

# 4. Tag if the version header is fresh (i.e. tag doesn't exist yet).
if (-not $NoTag -and $version) {
    $tag = "v$version"
    $existing = (& git tag --list $tag) -join ''
    if ([string]::IsNullOrWhiteSpace($existing)) {
        Run 'git' @('tag', '-a', $tag, '-m', $Message)
        Write-Host "  tagged  : $tag" -ForegroundColor Green
    } else {
        Write-Host "  tag $tag already exists - skipping." -ForegroundColor Yellow
    }
}

# 5. Push.
if (-not $NoPush) {
    Run 'git' @('push')
    if (-not $NoTag) { Run 'git' @('push', '--tags') }
}

Write-Host "  done." -ForegroundColor Green
