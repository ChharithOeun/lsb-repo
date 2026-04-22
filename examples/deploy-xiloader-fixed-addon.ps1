# deploy-xiloader-fixed-addon.ps1
#
# Self-contained deploy script: writes the xiloader_fixed Ashita v3 addon
# directly to F:\ffxi\Ashita\addons\xiloader_fixed\ from inline content,
# then re-points the Altana boot profile. No repo checkout required.
#
# Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File F:\ffxi\deploy\deploy-xiloader-fixed-addon.ps1
#
# Idempotent: re-running overwrites the addon and the boot profile after
# backing up.

$ErrorActionPreference = 'Stop'

$AshitaRoot  = 'F:\ffxi\Ashita'
$AddonsDir   = Join-Path $AshitaRoot 'addons'
$AddonRoot   = Join-Path $AddonsDir 'xiloader_fixed'
$SettingsDir = Join-Path $AddonRoot 'settings'
$RetailPol   = 'C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\pol.exe'
$XiLoader    = 'F:\ffxi\Ashita\ffxi-bootmod\pol.exe'
$BootProfile = Join-Path $AshitaRoot 'config\boot\Private Server.xml'
$Backups     = Join-Path $AshitaRoot 'config\_backups'
$Log         = 'F:\ffxi\deploy\deploy-xiloader-fixed-addon.log'

New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

Write-Host "== deploy-xiloader-fixed-addon ==" -ForegroundColor Cyan
Write-Host "AshitaRoot : $AshitaRoot"
Write-Host "AddonRoot  : $AddonRoot"
Write-Host "BootProfile: $BootProfile"
Write-Host "RetailPol  : $RetailPol"
Write-Host "XiLoader   : $XiLoader"

if (-not (Test-Path $AshitaRoot))   { throw "Ashita root missing: $AshitaRoot" }
if (-not (Test-Path $XiLoader))     { throw "xiloader missing: $XiLoader (run install-xiloader-2.1.1.ps1 first)" }
if (-not (Test-Path $BootProfile))  { throw "Boot profile missing: $BootProfile" }

New-Item -ItemType Directory -Force -Path $AddonsDir   | Out-Null
New-Item -ItemType Directory -Force -Path $AddonRoot   | Out-Null
New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
New-Item -ItemType Directory -Force -Path $Backups     | Out-Null

# --- Inline addon source --------------------------------------------------
$LuaAddon = @'
--[[ xiloader_fixed.lua - see addons/xiloader_fixed/README.md ]]
addon.name    = 'xiloader_fixed'
addon.author  = 'Chharbot / 2026-04-20 session'
addon.version = '1.0.0'
addon.desc    = 'Bridges xiloader 2.1.x with Ashita injector for LSB.'
addon.link    = 'https://github.com/LandSandBoat/xiloader'

require('common')
local chat     = require('chat')
local settings = require('settings')

local defaults = T{
    xiloader  = 'F:\\ffxi\\Ashita\\ffxi-bootmod\\pol.exe',
    server    = '127.0.0.1',
    user      = 'GUESTCL1',
    pass      = 'guestpass',
    hairpin   = true,
    hide      = true,
    autostart = true,
    delay_ms  = 250,
}

local config       = settings.load(defaults)
local last_run     = nil
local spawned_pids = T{}

local function log(msg) print(chat.header(addon.name) .. chat.message(msg)) end
local function err(msg) print(chat.header(addon.name) .. chat.error(msg))   end

local function build_command()
    local q = '"'
    local parts = T{ q .. config.xiloader .. q,
                    '--server',   config.server,
                    '--user',     config.user,
                    '--password', config.pass }
    if config.hairpin then parts:append('--hairpin') end
    if config.hide    then parts:append('--hide')    end
    return parts:concat(' ')
end

local function fire_xiloader()
    if not ashita.fs.exists(config.xiloader) then
        err('xiloader binary missing: ' .. config.xiloader); return false
    end
    local cmd = build_command()
    log('Launching xiloader: ' .. cmd)
    local pid = nil
    local ok, runner = pcall(function() return ashita.misc.execute_app end)
    if ok and runner then
        pid = ashita.misc.execute_app(cmd, false)
    elseif ashita.system and ashita.system.shell_exec then
        pid = ashita.system.shell_exec(cmd)
    else
        os.execute('start "" ' .. cmd); pid = -1
    end
    spawned_pids:append(pid)
    last_run = T{ time = os.time(), pid = pid, command = cmd }
    if pid and pid > 0 then
        log(('xiloader spawned (PID %d) -> %s'):format(pid, config.server))
    else
        log('xiloader spawned (PID unknown)')
    end
    return true
end

local function kill_spawned()
    if #spawned_pids == 0 then log('No tracked PIDs.'); return end
    for _, pid in ipairs(spawned_pids) do
        if pid and pid > 0 then os.execute(('taskkill /F /PID %d >nul 2>&1'):format(pid)) end
    end
    log(('Killed %d PID(s).'):format(#spawned_pids))
    spawned_pids = T{}
end

ashita.events.register('command', 'xilfix_command_cb', function(e)
    local args = e.command:args(); if #args == 0 then return end
    local head = args[1]:lower()
    if head ~= '/xilfix' and head ~= '/xiloader_fixed' then return end
    e.blocked = true
    local sub = (args[2] or 'status'):lower()
    if sub == 'status' then
        log('xiloader  = ' .. tostring(config.xiloader))
        log('server    = ' .. tostring(config.server))
        log('user      = ' .. tostring(config.user))
        log('pass      = ' .. string.rep('*', #config.pass))
        log('hairpin   = ' .. tostring(config.hairpin))
        log('hide      = ' .. tostring(config.hide))
        log('autostart = ' .. tostring(config.autostart))
        if last_run then log(('last_run  = pid=%s, %ds ago'):format(tostring(last_run.pid), os.time() - last_run.time)) end
    elseif sub == 'set' and args[3] and args[4] then
        local k, v = args[3]:lower(), args[4]
        if k == 'hairpin' or k == 'hide' or k == 'autostart' then
            config[k] = (v == 'true' or v == '1' or v == 'yes' or v == 'on')
        else config[k] = v end
        log(('set %s = %s'):format(k, tostring(config[k])))
    elseif sub == 'save' then settings.save(); log('settings.lua saved.')
    elseif sub == 'run' then fire_xiloader()
    elseif sub == 'kill' then kill_spawned()
    elseif sub == 'help' then log('/xilfix status | set <k> <v> | save | run | kill')
    else err('unknown subcommand: ' .. tostring(sub)); log('try /xilfix help') end
end)

settings.register('settings', 'settings_update', function(s) if s ~= nil then config = s end end)

local load_time   = 0
local autostarted = false

ashita.events.register('load', 'xilfix_load_cb', function()
    load_time = os.clock(); log('loaded - addon version ' .. addon.version)
    if not config.autostart then log('autostart=false; use /xilfix run.') end
end)

ashita.events.register('d3d_present', 'xilfix_present_cb', function()
    if autostarted or not config.autostart then return end
    if (os.clock() - load_time) * 1000 < config.delay_ms then return end
    autostarted = true; fire_xiloader()
end)

ashita.events.register('unload', 'xilfix_unload_cb', function() settings.save() end)
'@

$LuaSettings = @'
return T{
    xiloader  = 'F:\\ffxi\\Ashita\\ffxi-bootmod\\pol.exe',
    server    = '127.0.0.1',
    user      = 'GUESTCL1',
    pass      = 'guestpass',
    hairpin   = true,
    hide      = true,
    autostart = true,
    delay_ms  = 250,
}
'@

$Readme = @'
# xiloader_fixed (Ashita v3 addon)

Spawns xiloader 2.1.1 against the local LSB server during Ashita's
addon-load window. Set the boot profile to point at the RETAIL pol.exe
so Ashita has a real injection target.

Commands: /xilfix status | set <k> <v> | save | run | kill | help
'@

# --- Write addon files ----------------------------------------------------
$LuaAddon    | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $AddonRoot 'xiloader_fixed.lua')
$LuaSettings | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $SettingsDir 'settings.lua')
$Readme      | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $AddonRoot 'README.md')
Write-Host "Wrote addon files under $AddonRoot" -ForegroundColor Green

# --- Update boot profile --------------------------------------------------
$ts     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $Backups ("Private Server.xml.$ts.bak")
Copy-Item $BootProfile $backup
Write-Host "Backed up boot profile -> $backup"

[xml]$xml = Get-Content -LiteralPath $BootProfile
$nodes = $xml.settings.setting
function Set-Node($name, $value) {
    $n = $nodes | Where-Object { $_.name -eq $name }
    if (-not $n) { throw "Setting '$name' not found in $BootProfile" }
    $n.'#text' = $value
}

if (Test-Path $RetailPol) {
    Set-Node 'boot_file' $RetailPol
    Write-Host "boot_file -> retail pol.exe ($RetailPol)" -ForegroundColor Green
} else {
    Write-Host "Retail pol.exe not found at $RetailPol" -ForegroundColor Yellow
    Write-Host "Leaving boot_file pointing at xiloader; use the wrapper (Launch-Altana.bat) instead of relying on the addon." -ForegroundColor Yellow
}
Set-Node 'boot_command' '--server 127.0.0.1'
Set-Node 'config_name'  'Altana'
$xml.Save($BootProfile)
Write-Host "Updated boot profile" -ForegroundColor Green

# --- Best-effort: enable addon in Altana profile -------------------------
$AltanaCfg = Join-Path $AshitaRoot 'config\default\Altana.xml'
if (Test-Path $AltanaCfg) {
    $b2 = Join-Path $Backups ("Altana.xml.$ts.bak")
    Copy-Item $AltanaCfg $b2
    [xml]$altana = Get-Content -LiteralPath $AltanaCfg
    $addonsNode = $altana.SelectSingleNode('//addons')
    if ($addonsNode) {
        $existing = $addonsNode.addon | Where-Object { $_.'#text' -eq 'xiloader_fixed' -or $_.name -eq 'xiloader_fixed' }
        if (-not $existing) {
            $new = $altana.CreateElement('addon'); $new.InnerText = 'xiloader_fixed'
            $addonsNode.AppendChild($new) | Out-Null
            $altana.Save($AltanaCfg)
            Write-Host "Enabled xiloader_fixed in Altana profile" -ForegroundColor Green
        } else { Write-Host "xiloader_fixed already in Altana addon list" -ForegroundColor Yellow }
    } else { Write-Host "No <addons> node in $AltanaCfg - enable manually via Ashita UI" -ForegroundColor Yellow }
} else { Write-Host "$AltanaCfg not found - enable addon via in-game /load xiloader_fixed" -ForegroundColor Yellow }

Write-Host ""
Write-Host "DEPLOY COMPLETE." -ForegroundColor Green
Write-Host "Next: launch Ashita -> select 'Altana' -> Play. Capture output to F:\ffxi\deploy\altana-smoke-test.log." -ForegroundColor Green
Stop-Transcript | Out-Null
