# register-scheduled-task.ps1 - create a Windows Scheduled Task that runs
# lsb-version-sync at boot and every 6 hours thereafter. This is the
# "auto-bake" piece: when SE ships a retail patch that updates FFXiMain.dll,
# the task detects the new CLIENT_VER on the next run and updates LSB's
# login.lua + restarts login_server without any human involvement.
#
# Run ONCE from an elevated PowerShell prompt:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\register-scheduled-task.ps1
#
# Unregister with:
#   Unregister-ScheduledTask -TaskName 'LSB Version Sync' -Confirm:$false

param(
    [string]$TaskName   = 'LSB Version Sync',
    [string]$ScriptPath = $null,                     # defaults to sibling lsb-version-sync.ps1
    [int]   $IntervalHours = 6,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "unregistered '$TaskName'" -ForegroundColor Green
    } catch {
        Write-Host "task '$TaskName' not registered" -ForegroundColor Yellow
    }
    exit 0
}

if (-not $ScriptPath) {
    $ScriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lsb-version-sync.ps1'
}
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "wrapper script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" scheduled"

# Run at startup, then every $IntervalHours hours for 24h, repeating forever.
$triggerBoot   = New-ScheduledTaskTrigger -AtStartup
$triggerDaily  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 365)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger @($triggerBoot, $triggerDaily) `
    -Principal $principal `
    -Settings $settings `
    -Description 'Auto-match retail FFXI CLIENT_VER to LSB login.lua; runs lsb_version_sync.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
Write-Host "registered scheduled task '$TaskName' (boot + every $IntervalHours h)" -ForegroundColor Green
