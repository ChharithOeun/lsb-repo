# install-xiloader-2.1.1-offline.ps1
# Same effect as install-xiloader-2.1.1.ps1 but skips the GitHub download and uses a
# pre-staged binary already copied onto the Windows box. Use this if the machine
# can't reach github.com or release-assets.githubusercontent.com.
#
# Prereq: copy xiloader-2.1.1.exe (the pre-verified binary from the repo's
# binaries/ folder) to F:\ffxi\deploy\xiloader-2.1.1.exe before running.

$ErrorActionPreference = 'Stop'

$Target        = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$BackupPath    = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe.bootloader.bak'
$StagingFile   = 'F:\ffxi\deploy\xiloader-2.1.1.exe'
$ExpectedMd5   = '44FE5F23BF76E4E847946B5B76F1E061'
$ExpectedSize  = 1072128
$LogPath       = 'F:\ffxi\deploy\install-xiloader-2.1.1-offline.log'

Start-Transcript -Path $LogPath -Force | Out-Null

function Get-Md5([string]$Path) {
    (Get-FileHash -Algorithm MD5 -Path $Path).Hash.ToUpperInvariant()
}

if (-not (Test-Path $StagingFile)) {
    throw "Staged binary not found at $StagingFile. Copy it there first."
}

$stagedSize = (Get-Item $StagingFile).Length
$stagedMd5  = Get-Md5 $StagingFile
if ($stagedSize -ne $ExpectedSize) { throw "Staged size mismatch: got $stagedSize, expected $ExpectedSize." }
if ($stagedMd5  -ne $ExpectedMd5)  { throw "Staged MD5 mismatch: got $stagedMd5, expected $ExpectedMd5." }
Write-Host "Staged binary verified: $stagedSize bytes, MD5 $stagedMd5" -ForegroundColor Green

if ((Test-Path $Target) -and -not (Test-Path $BackupPath)) {
    Copy-Item $Target $BackupPath -Force
    Write-Host "Backup saved to $BackupPath" -ForegroundColor Green
}

Copy-Item $StagingFile $Target -Force
$finalMd5 = Get-Md5 $Target
if ($finalMd5 -ne $ExpectedMd5) { throw "Post-copy MD5 mismatch: $finalMd5" }
Write-Host "Installed. MD5 matches expected xiloader 2.1.1." -ForegroundColor Green

Stop-Transcript | Out-Null
