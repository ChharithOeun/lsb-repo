# run-all-fixes.ps1
#
# One-click orchestrator for the full 2026-04-20 auth-fix deploy.
# Runs, in order:
#   1. install-ashita-xiloader-addon.ps1
#   2. upgrade-windower-xiloader.ps1
#   3. verify-guest-login.ps1
#
# Each step is wrapped so a failure in one does not abort the rest — the
# summary at the end reports PASS/FAIL/SKIP per step.
#
# USAGE:
#   Right-click -> Run with PowerShell
#   OR double-click run-all-fixes.bat (sister file)
#
# Safe to re-run. Every underlying script is idempotent.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Steps = @(
    @{ Name = 'Ashita addon install'; Script = 'install-ashita-xiloader-addon.ps1' }
    @{ Name = 'Windower xiloader upgrade'; Script = 'upgrade-windower-xiloader.ps1' }
    @{ Name = 'Guest login verification'; Script = 'verify-guest-login.ps1' }
)

$results = @()

foreach ($step in $Steps) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host ">> {0}" -f $step.Name -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan

    $path = Join-Path $ScriptRoot $step.Script
    if (-not (Test-Path $path)) {
        Write-Host "Script not found: $path" -ForegroundColor Red
        $results += @{ Name = $step.Name; Status = 'MISSING'; ExitCode = -1 }
        continue
    }

    try {
        & powershell.exe -ExecutionPolicy Bypass -File $path
        $code = $LASTEXITCODE
    } catch {
        Write-Host "Exception: $_" -ForegroundColor Red
        $code = 1
    }

    $status = switch ($code) {
        0 { 'PASS' }
        2 { 'SKIP (prereq missing)' }
        3 { 'SKIP (addon source not staged)' }
        default { 'FAIL' }
    }
    $color = switch ($status) {
        'PASS' { 'Green' }
        { $_ -like 'SKIP*' } { 'Yellow' }
        default { 'Red' }
    }
    Write-Host "[$($step.Name)] -> $status (exit $code)" -ForegroundColor $color
    $results += @{ Name = $step.Name; Status = $status; ExitCode = $code }
}

Write-Host ""
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host ">> Summary" -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        { $_ -like 'SKIP*' } { 'Yellow' }
        default { 'Red' }
    }
    "{0,-30}  {1}" -f $r.Name, $r.Status | Write-Host -ForegroundColor $color
}

$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'MISSING' }).Count
if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "$failCount step(s) failed. See output above." -ForegroundColor Red
    exit 1
}

$skipCount = ($results | Where-Object { $_.Status -like 'SKIP*' }).Count
if ($skipCount -gt 0) {
    Write-Host ""
    Write-Host "$skipCount step(s) skipped (prereq or optional). Core fix is still applied." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Launch Ashita -> Altana -> Play, or run xiloader directly." -ForegroundColor Green
exit 0
