# install-ashita-xiloader-addon.ps1
#
# Installs the xiloader_fixed Ashita addon so the Altana profile can hand off
# from xiloader to the retail pol.exe with Ashita injecting into the spawned
# child. This is the missing piece after the 2026-04-20 auth fix.
#
# What this does:
#   1. Locates Ashita v3 (F:\ffxi\Ashita by default)
#   2. Copies addons/xiloader_fixed from the repo into the addons folder
#   3. Re-points Private Server.xml boot_file at the retail pol.exe
#   4. Enables the addon in the profile's default.xml (best-effort)
#   5. Saves a backup of any modified config
#
# This script is conservative: it backs up before overwriting, and exits
# cleanly if prerequisites (Ashita, retail pol.exe) aren't found.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File install-ashita-xiloader-addon.ps1
#
# After running:
#   Launch Ashita -> select "Altana" profile -> Play
#   xiloader 2.1.1 authenticates -> spawned pol.exe is injected -> character select

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$AshitaRoot  = 'F:\ffxi\Ashita'
$RetailPol   = 'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe'
$ProfilePath = Join-Path $AshitaRoot 'config\boot\Private Server.xml'
$AddonName   = 'xiloader_fixed'
$Backups     = Join-Path $AshitaRoot 'config\_backups'

# Resolve the addon source from THIS script's location: it lives at
# <repo>/examples/install-ashita-xiloader-addon.ps1, addon source is at
# <repo>/addons/xiloader_fixed/.
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$AddonSource = Join-Path $RepoRoot 'addons\xiloader_fixed'

Write-Host "== Ashita xiloader addon install ==" -ForegroundColor Cyan
Write-Host "Repo root  : $RepoRoot"
Write-Host "Addon src  : $AddonSource"
Write-Host "Ashita root: $AshitaRoot"
Write-Host "Retail pol : $RetailPol"
Write-Host ""

# -- 1. Prereqs ---------------------------------------------------------------
foreach ($needed in @($AshitaRoot, $ProfilePath)) {
    if (-not (Test-Path $needed)) { throw "Required path missing: $needed" }
}
if (-not (Test-Path $AddonSource)) {
    throw "Addon source missing: $AddonSource (run from inside the repo, not from a copy)"
}
if (-not (Test-Path $RetailPol)) {
    Write-Host "Retail pol.exe not found at:" -ForegroundColor Red
    Write-Host "  $RetailPol" -ForegroundColor Red
    Write-Host "Install FFXI via Steam or adjust `$RetailPol at the top of this script." -ForegroundColor Red
    exit 2
}
New-Item -ItemType Directory -Path $Backups -Force | Out-Null

# -- 2. Addon install ---------------------------------------------------------
$AddonsDir = Join-Path $AshitaRoot 'addons'
if (-not (Test-Path $AddonsDir)) {
    New-Item -ItemType Directory -Path $AddonsDir | Out-Null
}
$AddonDest = Join-Path $AddonsDir $AddonName
if (Test-Path $AddonDest) {
    $b = Join-Path $Backups ("$AddonName.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -Recurse $AddonDest $b
    Write-Host "Existing addon backed up to $b" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $AddonDest
}
Copy-Item -Recurse $AddonSource $AddonDest
Write-Host "Installed addon: $AddonDest" -ForegroundColor Green

# -- 3. Profile update --------------------------------------------------------
$backup = Join-Path $Backups ("Private Server.xml.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $ProfilePath $backup
Write-Host "Backed up profile to $backup"

[xml]$xml = Get-Content -LiteralPath $ProfilePath
$nodes = $xml.settings.setting
function Set-Node($name, $value) {
    $n = $nodes | Where-Object { $_.name -eq $name }
    if (-not $n) { throw "Setting '$name' not found in $ProfilePath" }
    $n.'#text' = $value
}
Set-Node 'boot_file'    $RetailPol
Set-Node 'boot_command' '--server 127.0.0.1'
Set-Node 'config_name'  'Altana'
$xml.Save($ProfilePath)
Write-Host "Updated $ProfilePath (boot_file -> retail pol.exe)" -ForegroundColor Green

# -- 4. Enable addon in Altana's default.xml ----------------------------------
$AltanaCfg = Join-Path $AshitaRoot 'config\default\Altana.xml'
if (Test-Path $AltanaCfg) {
    $backup2 = Join-Path $Backups ("Altana.xml.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $AltanaCfg $backup2
    [xml]$altana = Get-Content -LiteralPath $AltanaCfg
    # Addon list schema varies by Ashita version; this is best-effort
    $addonsNode = $altana.SelectSingleNode('//addons')
    if ($addonsNode) {
        $existing = $addonsNode.addon | Where-Object { $_.'#text' -eq $AddonName -or $_.name -eq $AddonName }
        if (-not $existing) {
            $new = $altana.CreateElement('addon')
            $new.InnerText = $AddonName
            $addonsNode.AppendChild($new) | Out-Null
            $altana.Save($AltanaCfg)
            Write-Host "Enabled $AddonName in Altana profile" -ForegroundColor Green
        } else {
            Write-Host "$AddonName already enabled in Altana" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No <addons> node in Altana.xml — enable the addon manually in Ashita's config UI." -ForegroundColor Yellow
    }
} else {
    Write-Host "Altana profile config not found at $AltanaCfg" -ForegroundColor Yellow
    Write-Host "After first launch, run /load xiloader_fixed at the in-game console, then save." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Launch Ashita -> select 'Altana' -> Play." -ForegroundColor Green
Write-Host "Expected: xiloader 2.1.1 authenticates -> spawns pol.exe -> Ashita injects -> character select." -ForegroundColor Green
