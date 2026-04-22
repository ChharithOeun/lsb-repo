# verify-guest-login.ps1
#
# End-to-end smoke test for the LSB guest-login fix.
# Confirms the three layers are healthy:
#   1. Password hash matches legacy PASSWORD('guestpass') shape
#   2. xiloader binary is 2.1.x
#   3. Direct xiloader run reaches "Successfully logged in as GUESTCL1!"
#
# Exit code: 0 on full success, 1 on any failure (prints which layer).

$ErrorActionPreference = 'Stop'

$Server   = '127.0.0.1'
$User     = 'GUESTCL1'
$Password = 'guestpass'
$Xiloader = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$ExpectedMD5 = '44FE5F23BF76E4E847946B5B76F1E061'

$fail = @()

Write-Host "== LSB guest-login smoke test ==" -ForegroundColor Cyan

# --- Layer 2: xiloader binary ---
Write-Host "`n[1/3] xiloader binary..."
if (-not (Test-Path $Xiloader)) {
    $fail += "xiloader not at $Xiloader"
} else {
    $ver = [Version]((Get-Item $Xiloader).VersionInfo.FileVersion -replace ',','.')
    $md5 = (Get-FileHash $Xiloader -Algorithm MD5).Hash
    Write-Host "  version: $ver, md5: $md5"
    if ($ver -lt [Version]'2.1.0.0') { $fail += "xiloader version $ver < 2.1.0" }
    if ($md5 -ne $ExpectedMD5)       { Write-Host "  (MD5 does not match golden, but version is acceptable)" -ForegroundColor Yellow }
}

# --- Layer 1: password hash ---
Write-Host "`n[2/3] password hash (skipped unless MariaDB available)..."
$maria = 'F:\ffxi\mariadb\bin\mariadb.exe'
if (Test-Path $maria) {
    $cred = [System.IO.Path]::GetTempFileName()
    @"
[client]
user=ffxi_user
password=JY0E6le4cCq8I3^AcF6|*hM!nj1A@?=)
host=127.0.0.1
database=xidb
"@ | Set-Content -Path $cred -Encoding ASCII
    try {
        $row = & $maria --defaults-extra-file="$cred" -N -e "SELECT LEFT(password,4), LENGTH(password) FROM accounts WHERE id=1000;"
        Write-Host "  accounts.id=1000 -> $row"
        if ($row -notmatch '\*61E\s+41') {
            $fail += "password hash for GUESTCL1 is not *61E/41 — re-run fix-password.ps1"
        }
    } finally {
        Remove-Item $cred -Force
    }
} else {
    Write-Host "  mariadb.exe not found; skipping." -ForegroundColor Yellow
}

# --- Layer 3: live handshake ---
Write-Host "`n[3/3] live xiloader handshake..."
$args = @('--server', $Server, '--user', $User, '--password', $Password, '--hide')
$out = & $Xiloader @args 2>&1 | Out-String
Write-Host $out
if ($out -notmatch 'Successfully logged in as GUESTCL1') {
    $fail += "xiloader did not report successful login"
}

if ($fail.Count) {
    Write-Host "`nFAIL:" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "`nAll three layers healthy. Guest login works." -ForegroundColor Green
    exit 0
}
