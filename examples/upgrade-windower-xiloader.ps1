# upgrade-windower-xiloader.ps1
#
# Mirrors the ffxi-bootmod xiloader 2.1.1 upgrade for Windower 4.
# Run as the interactive user (no admin needed unless Windower is in Program Files).
#
# Behaviour:
#   1. Locates Windower's xiloader.exe (common install paths, then Get-ChildItem fallback)
#   2. Verifies the current FileVersion
#   3. If below 2.1.0, backs up to xiloader.exe.v<old>.bak
#   4. Copies the known-good 2.1.1 binary from F:\ffxi\Ashita\ffxi-bootmod\pol.exe
#   5. Verifies MD5 matches 44FE5F23BF76E4E847946B5B76F1E061
#
# Safe to re-run: a current 2.1.1 installation is a no-op.

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

$ExpectedMD5 = '44FE5F23BF76E4E847946B5B76F1E061'
$GoldenCopy  = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$MinVersion  = [Version]'2.1.0.0'

$CandidatePaths = @(
    'C:\Program Files (x86)\Windower4\xiloader.exe'
    'C:\Windower4\xiloader.exe'
    (Join-Path $env:APPDATA 'Windower4\xiloader.exe')
    (Join-Path $env:USERPROFILE 'Windower4\xiloader.exe')
    'D:\Windower4\xiloader.exe'
)

function Find-Xiloader {
    foreach ($p in $CandidatePaths) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    Write-Host "Not in standard locations; scanning drives C: D: E: F:..." -ForegroundColor Yellow
    foreach ($drive in 'C:\','D:\','E:\','F:\') {
        if (Test-Path $drive) {
            $hit = Get-ChildItem -Path $drive -Filter 'xiloader.exe' -Recurse -ErrorAction SilentlyContinue -Force |
                   Where-Object { $_.FullName -match 'Windower' } |
                   Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

Write-Host "== Windower xiloader upgrade ==" -ForegroundColor Cyan

if (-not (Test-Path $GoldenCopy)) {
    throw "Golden copy of xiloader 2.1.1 not found at $GoldenCopy. Run the Ashita upgrade first."
}
$goldenHash = (Get-FileHash $GoldenCopy -Algorithm MD5).Hash
if ($goldenHash -ne $ExpectedMD5) {
    throw "Golden copy MD5 mismatch. Got $goldenHash, expected $ExpectedMD5. Refuse to copy."
}

$target = Find-Xiloader
if (-not $target) {
    Write-Host "Could not locate Windower's xiloader.exe. Install Windower 4 or pass the path explicitly." -ForegroundColor Red
    exit 2
}
Write-Host "Found: $target"

$currentVer = [Version]((Get-Item $target).VersionInfo.FileVersion -replace ',','.')
Write-Host "Current version: $currentVer"

if ($currentVer -ge $MinVersion) {
    $currHash = (Get-FileHash $target -Algorithm MD5).Hash
    if ($currHash -eq $ExpectedMD5) {
        Write-Host "Already on 2.1.1 (MD5 matches). Nothing to do." -ForegroundColor Green
        exit 0
    }
    Write-Host "Version is >= 2.1.0 but MD5 differs from golden. Overwriting anyway." -ForegroundColor Yellow
}

$backup = "$target.v$currentVer.bak"
if (-not (Test-Path $backup)) {
    Copy-Item $target $backup
    Write-Host "Backed up to $backup"
} else {
    Write-Host "Backup already present: $backup (leaving untouched)"
}

Copy-Item $GoldenCopy $target -Force
$newHash = (Get-FileHash $target -Algorithm MD5).Hash
if ($newHash -ne $ExpectedMD5) {
    throw "Post-copy MD5 mismatch. Expected $ExpectedMD5, got $newHash."
}
Write-Host "Upgrade complete. $target is now xiloader 2.1.1 (MD5 $newHash)." -ForegroundColor Green
