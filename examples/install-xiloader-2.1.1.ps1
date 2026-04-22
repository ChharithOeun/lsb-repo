# install-xiloader-2.1.1.ps1
# Replaces F:\ffxi\Ashita\ffxi-bootmod\pol.exe (47 KB Ashita Bootloader, 2014-2017)
# with real xiloader 2.1.1 (~1 MB) so auto-login via --user/--password works headlessly.
#
# Download URL and MD5 were verified on 2026-04-20 against the LSB fork release:
#   https://github.com/LandSandBoat/xiloader/releases/download/v2.1.1/xiloader.exe
#   MD5: 44FE5F23BF76E4E847946B5B76F1E061
#   Size: 1,072,128 bytes
#
# Run from any PowerShell (no elevation needed unless pol.exe is locked by a running
# process — if so, script tries to Stop-Process it first).
# Idempotent: re-running is safe. Short-circuits if MD5 already matches.

$ErrorActionPreference = 'Stop'

$Target        = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$BackupPath    = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak'
$DownloadUrl   = 'https://github.com/LandSandBoat/xiloader/releases/download/v2.1.1/xiloader.exe'
$ExpectedMd5   = '44FE5F23BF76E4E847946B5B76F1E061'
$ExpectedSize  = 1072128
$StagingDir    = 'F:\ffxi\deploy'
$StagingFile   = Join-Path $StagingDir 'xiloader-2.1.1.exe'
$LogPath       = Join-Path $StagingDir 'install-xiloader-2.1.1.log'

New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Get-Md5([string]$Path) {
    (Get-FileHash -Algorithm MD5 -Path $Path).Hash.ToUpperInvariant()
}

Write-Host "=== xiloader 2.1.1 installer ===" -ForegroundColor Cyan
Write-Host "Target:  $Target"
Write-Host "Backup:  $BackupPath"
Write-Host "Staging: $StagingFile"
Write-Host ""

# --- Step 0: kill any running pol.exe / xiloader / Ashita that might hold the target
foreach ($name in 'pol','xiloader','Ashita','injector') {
    Get-Process $name -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopping $($_.Name) PID $($_.Id) ..." -ForegroundColor Yellow
        try { $_ | Stop-Process -Force -ErrorAction Stop }
        catch { Write-Host "  (could not kill $($_.Name) PID $($_.Id): $($_.Exception.Message))" -ForegroundColor Red }
    }
}

# --- Step 1: short-circuit if already installed ---
if (Test-Path $Target) {
    $currentSize = (Get-Item $Target).Length
    $currentMd5  = Get-Md5 $Target
    Write-Host "Current target binary: $currentSize bytes, MD5 $currentMd5"
    if ($currentMd5 -eq $ExpectedMd5) {
        Write-Host "Already xiloader 2.1.1. Nothing to do." -ForegroundColor Green
        Stop-Transcript | Out-Null
        exit 0
    }
}

# --- Step 2: download (or reuse staged) ---
$needDownload = $true
if (Test-Path $StagingFile) {
    $stagedMd5 = Get-Md5 $StagingFile
    if ($stagedMd5 -eq $ExpectedMd5) {
        Write-Host "Staged binary already matches expected MD5, skipping download." -ForegroundColor Green
        $needDownload = $false
    } else {
        Write-Host "Staged binary MD5 mismatch, re-downloading..." -ForegroundColor Yellow
        Remove-Item $StagingFile -Force
    }
}

if ($needDownload) {
    Write-Host "Downloading from $DownloadUrl ..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $StagingFile -UseBasicParsing
    $stagedSize = (Get-Item $StagingFile).Length
    $stagedMd5  = Get-Md5 $StagingFile
    Write-Host "Downloaded: $stagedSize bytes, MD5 $stagedMd5"
    if ($stagedSize -ne $ExpectedSize) { throw "Size mismatch on download ($stagedSize vs $ExpectedSize)." }
    if ($stagedMd5  -ne $ExpectedMd5)  { throw "MD5 mismatch on download ($stagedMd5 vs $ExpectedMd5)." }
    Write-Host "Download verified." -ForegroundColor Green
}

# --- Step 3: back up the current target ---
if (Test-Path $Target) {
    if (-not (Test-Path $BackupPath)) {
        Copy-Item $Target $BackupPath -Force
        Write-Host "Backed up current pol.exe to $BackupPath" -ForegroundColor Green
    } else {
        Write-Host "Backup already exists - leaving alone." -ForegroundColor Yellow
    }
}

# --- Step 4: install ---
Copy-Item $StagingFile $Target -Force
$finalSize = (Get-Item $Target).Length
$finalMd5  = Get-Md5 $Target
Write-Host "Final: $finalSize bytes, MD5 $finalMd5"
if ($finalMd5 -ne $ExpectedMd5) { throw "Post-copy MD5 mismatch: $finalMd5" }
Write-Host "INSTALL SUCCEEDED - xiloader 2.1.1 is now at $Target" -ForegroundColor Green

Stop-Transcript | Out-Null
