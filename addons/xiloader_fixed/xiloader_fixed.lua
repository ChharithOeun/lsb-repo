--[[
xiloader_fixed.lua
==================
Ashita v3 addon that bridges xiloader 2.1.x with Ashita's injector for the
LandSandBoat Altana profile.

The problem this solves
-----------------------
Ashita v3 launches a `boot_file` and injects AshitaCore.dll into THAT
process. xiloader is not a valid injection target — it's a short-lived
auth helper that exits after spawning the real `pol.exe`. So pointing
`boot_file` directly at xiloader gives you authentication but no
in-game Ashita features.

The fix
-------
1. Set `boot_file` to the retail `pol.exe` so Ashita has a real injection
   target.
2. This addon runs xiloader as a sibling process during the brief window
   before Ashita injects. xiloader does the LSB handshake, then the real
   FFXI client picks up where xiloader left off because xiloader writes
   the session token into `polcore`'s expected location and then xiloader
   exits.

Usage
-----
1. Copy this folder to `<AshitaRoot>/addons/xiloader_fixed/`.
2. Set the Altana profile's `boot_file` to the retail pol.exe path.
3. Set `boot_command` to empty (or `--server 127.0.0.1` if you want to
   override).
4. Add `/load xiloader_fixed` to your default.txt or enable it in the
   Ashita config UI for the Altana profile.
5. Optional: configure credentials with
       /xilfix set user GUESTCL1
       /xilfix set pass guestpass
       /xilfix set server 127.0.0.1
       /xilfix save
6. Click Play.

Commands
--------
/xilfix status       - Show current settings and last spawn result.
/xilfix set <k> <v>  - Update a setting (server | user | pass | xiloader |
                       hairpin | hide | autostart).
/xilfix save         - Persist settings to settings.lua.
/xilfix run          - Manually fire xiloader against the current settings.
/xilfix kill         - Kill any xiloader child processes this addon spawned.
--]]

addon.name      = 'xiloader_fixed'
addon.author    = 'Chharbot / 2026-04-20 session'
addon.version   = '1.0.0'
addon.desc      = 'Bridges xiloader 2.1.x with Ashita injector for LSB.'
addon.link      = 'https://github.com/LandSandBoat/xiloader'

require('common')
local chat     = require('chat')
local settings = require('settings')

----------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------
local defaults = T{
    xiloader  = 'F:\\ffxi\\Ashita\\ffxi-bootmod\\pol.exe',
    server    = '127.0.0.1',
    user      = 'GUESTCL1',
    pass      = 'guestpass',
    hairpin   = true,
    hide      = true,
    autostart = true,
    -- How many milliseconds after addon load before we fire xiloader.
    -- Gives Ashita's main loop a tick to settle.
    delay_ms  = 250,
}

local config       = settings.load(defaults)
local last_run     = nil       -- table { time, exitcode, command }
local spawned_pids = T{}       -- list of PIDs we've launched, for /xilfix kill

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function log(msg, color)
    color = color or 207        -- light cyan
    print(chat.header(addon.name) .. chat.message(msg))
end

local function err(msg)
    print(chat.header(addon.name) .. chat.error(msg))
end

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

----------------------------------------------------------------------
-- Process spawn (uses Ashita's shell_exec which returns a PID)
----------------------------------------------------------------------
local function fire_xiloader()
    if not ashita.fs.exists(config.xiloader) then
        err('xiloader binary missing: ' .. config.xiloader)
        return false
    end
    local cmd = build_command()
    log('Launching xiloader: ' .. cmd, 207)
    -- ashita.misc.execute_app spawns and returns the PID.
    -- Older v3 builds expose this as ashita.system.shell_exec — fall back
    -- if needed.
    local pid = nil
    local ok, runner = pcall(function() return ashita.misc.execute_app end)
    if ok and runner then
        pid = ashita.misc.execute_app(cmd, false)   -- non-blocking
    elseif ashita.system and ashita.system.shell_exec then
        pid = ashita.system.shell_exec(cmd)
    else
        os.execute('start "" ' .. cmd)              -- last-ditch
        pid = -1
    end
    spawned_pids:append(pid)
    last_run = T{ time = os.time(), pid = pid, command = cmd }
    if pid and pid > 0 then
        log(('xiloader spawned (PID %d). Authenticating against %s ...'):format(pid, config.server), 207)
    else
        log('xiloader spawned (PID unknown). Watch the LSB log for the handshake.', 207)
    end
    return true
end

----------------------------------------------------------------------
-- Cleanup helper for /xilfix kill
----------------------------------------------------------------------
local function kill_spawned()
    if #spawned_pids == 0 then
        log('No spawned xiloader processes tracked.')
        return
    end
    for _, pid in ipairs(spawned_pids) do
        if pid and pid > 0 then
            os.execute(('taskkill /F /PID %d >nul 2>&1'):format(pid))
        end
    end
    log(('Killed %d tracked PID(s).'):format(#spawned_pids))
    spawned_pids = T{}
end

----------------------------------------------------------------------
-- Command handler
----------------------------------------------------------------------
ashita.events.register('command', 'xilfix_command_cb', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local head = args[1]:lower()
    if head ~= '/xilfix' and head ~= '/xiloader_fixed' then return end
    e.blocked = true

    local sub = (args[2] or 'status'):lower()
    if sub == 'status' then
        log(('xiloader  = %s'):format(config.xiloader))
        log(('server    = %s'):format(config.server))
        log(('user      = %s'):format(config.user))
        log(('pass      = %s'):format(string.rep('*', #config.pass)))
        log(('hairpin   = %s'):format(tostring(config.hairpin)))
        log(('hide      = %s'):format(tostring(config.hide)))
        log(('autostart = %s'):format(tostring(config.autostart)))
        if last_run then
            log(('last_run  = pid=%s, %s ago'):format(
                tostring(last_run.pid),
                tostring(os.time() - last_run.time) .. 's'))
        end
    elseif sub == 'set' and args[3] and args[4] then
        local k, v = args[3]:lower(), args[4]
        if k == 'hairpin' or k == 'hide' or k == 'autostart' then
            config[k] = (v == 'true' or v == '1' or v == 'yes' or v == 'on')
        else
            config[k] = v
        end
        log(('set %s = %s'):format(k, tostring(config[k])))
    elseif sub == 'save' then
        settings.save()
        log('settings.lua saved.')
    elseif sub == 'run' then
        fire_xiloader()
    elseif sub == 'kill' then
        kill_spawned()
    elseif sub == 'help' then
        log('/xilfix status | set <k> <v> | save | run | kill')
    else
        err('unknown subcommand: ' .. tostring(sub))
        log('try /xilfix help')
    end
end)

----------------------------------------------------------------------
-- Settings update hook
----------------------------------------------------------------------
settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        config = s
    end
end)

----------------------------------------------------------------------
-- Load: optionally autostart xiloader after a tiny delay
----------------------------------------------------------------------
local load_time   = 0
local autostarted = false

ashita.events.register('load', 'xilfix_load_cb', function()
    load_time = os.clock()
    log('loaded — addon version ' .. addon.version)
    if not config.autostart then
        log('autostart=false; use /xilfix run to fire manually.')
    end
end)

ashita.events.register('d3d_present', 'xilfix_present_cb', function()
    if autostarted or not config.autostart then return end
    if (os.clock() - load_time) * 1000 < config.delay_ms then return end
    autostarted = true
    fire_xiloader()
end)

ashita.events.register('unload', 'xilfix_unload_cb', function()
    settings.save()
end)
