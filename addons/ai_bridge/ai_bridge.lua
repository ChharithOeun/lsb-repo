--[[
ai_bridge (Ashita v3 classic rewrite)
TCP JSON-RPC listener on 127.0.0.1:27115 for Chharbot.
Uses ONLY the Ashita v3 classic API: _addon, ashita.register_event,
require('json.json'), require('socket'), AshitaCore:GetDataManager().
]]

_addon.author   = 'Chharbot / Claude';
_addon.name     = 'ai_bridge';
_addon.version  = '0.2.0';

require 'common'

-- ---------------------------------------------------------------------------
-- Trace log helper (writes to Ashita\logs\ai_bridge_trace.log)
-- ---------------------------------------------------------------------------
local function trace(msg)
    local ok, f = pcall(io.open, 'F:\\ffxi\\Ashita\\logs\\ai_bridge_trace.log', 'a')
    if ok and f then
        f:write(os.date('%Y-%m-%d %H:%M:%S ') .. tostring(msg) .. '\n')
        f:close()
    end
end

trace('--- ai_bridge top-level start ---')

-- ---------------------------------------------------------------------------
-- Requires (guarded)
-- ---------------------------------------------------------------------------
local ok_sock, socket = pcall(require, 'socket')
trace('require socket => ok=' .. tostring(ok_sock) .. ' type=' .. type(socket))
if not ok_sock then trace('socket err: ' .. tostring(socket)) end

local ok_json, json = pcall(require, 'json.json')
trace('require json.json => ok=' .. tostring(ok_json) .. ' type=' .. type(json))

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local settings = {
    host          = '127.0.0.1',
    port          = 27115,
    backlog       = 4,
    max_clients   = 4,
    chat_tail_max = 200,
    max_entities_radius = 50,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local state = {
    listener  = nil,
    clients   = {},    -- array of { sock = s, buf = '' }
    chat_tail = {},    -- ring of recent chat lines
    running   = false,
}

-- ---------------------------------------------------------------------------
-- JSON encode/decode shim
-- ---------------------------------------------------------------------------
local function encode(v)
    if ok_json and json and json.encode then
        local ok, s = pcall(function() return json:encode(v) end)
        if ok then return s end
    end
    -- Fallback: minimal encoder for primitives / flat tables
    if v == nil then return 'null' end
    local t = type(v)
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end
    if t == 'table' then
        -- check if array-like
        local is_arr = (#v > 0)
        local parts = {}
        if is_arr then
            for i = 1, #v do parts[#parts+1] = encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            for k, val in pairs(v) do
                parts[#parts+1] = '"' .. tostring(k) .. '":' .. encode(val)
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return '"' .. tostring(v) .. '"'
end

local function decode(s)
    if ok_json and json and json.decode then
        local ok, v = pcall(function() return json:decode(s) end)
        if ok then return v end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Game state readers (Ashita v3 DataManager API)
-- ---------------------------------------------------------------------------
local function safe_call(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function player_state()
    local dm    = AshitaCore:GetDataManager()
    local party = dm:GetParty()
    local target = dm:GetTarget()
    local player = dm:GetPlayer()
    local out = {
        name      = safe_call(function() return party:GetMemberName(0) end) or '?',
        zone_id   = safe_call(function() return party:GetMemberZone(0) end) or 0,
        hp        = safe_call(function() return party:GetMemberCurrentHP(0) end) or 0,
        hp_max    = safe_call(function() return party:GetMemberMaxHP(0) end) or 0,
        mp        = safe_call(function() return party:GetMemberCurrentMP(0) end) or 0,
        mp_max    = safe_call(function() return party:GetMemberMaxMP(0) end) or 0,
        tp        = safe_call(function() return party:GetMemberCurrentTP(0) end) or 0,
        main_job  = safe_call(function() return player:GetMainJob() end) or 0,
        sub_job   = safe_call(function() return player:GetSubJob() end) or 0,
        main_level = safe_call(function() return player:GetMainJobLevel() end) or 0,
        sub_level  = safe_call(function() return player:GetSubJobLevel() end) or 0,
        target_id  = safe_call(function() return target:GetServerId() end) or 0,
        target_name = safe_call(function() return target:GetName() end) or '',
    }
    return out
end

local function entities_within(radius)
    radius = math.min(radius or 30, settings.max_entities_radius)
    local dm = AshitaCore:GetDataManager()
    local entity = dm:GetEntity()
    local out = {}
    for i = 1, 2303 do
        local name = safe_call(function() return entity:GetName(i) end)
        if name and name ~= '' then
            local hpp = safe_call(function() return entity:GetHPPercent(i) end) or 0
            local sid = safe_call(function() return entity:GetServerId(i) end) or 0
            out[#out+1] = { idx = i, id = sid, name = name, hp_pct = hpp }
            if #out >= 128 then break end
        end
    end
    return out
end

local function chat_tail(n)
    n = math.min(n or 20, settings.chat_tail_max)
    local start = math.max(1, #state.chat_tail - n + 1)
    local out = {}
    for i = start, #state.chat_tail do out[#out+1] = state.chat_tail[i] end
    return out
end

-- ---------------------------------------------------------------------------
-- RPC dispatch
-- ---------------------------------------------------------------------------
local methods = {}

methods.ping = function(params)
    return { ok = true, ts = os.time() }
end

methods.get_state = function(params)
    return player_state()
end

methods.get_chat_tail = function(params)
    local n = (params and params.n) or 20
    return chat_tail(n)
end

methods.get_entities = function(params)
    local r = (params and params.radius) or 30
    return entities_within(r)
end

methods.send_text = function(params)
    local txt = params and params.text or ''
    if txt ~= '' then
        local ok = pcall(function() AshitaCore:GetChatManager():QueueCommand(txt, 1) end)
        return { ok = ok }
    end
    return { ok = false, error = 'empty text' }
end

methods.target = function(params)
    -- server-id based targeting via /ta (if addon is loaded in xiloader build)
    local id = params and params.entity_id
    if not id then return { ok = false, error = 'missing entity_id' } end
    local ok = pcall(function()
        AshitaCore:GetChatManager():QueueCommand('/ta <' .. tostring(id) .. '>', 1)
    end)
    return { ok = ok }
end

local function handle_request(raw)
    local req = decode(raw)
    local id  = (req and req.id) or 0
    local method = req and req.method
    local params = req and req.params

    if not method then
        return encode({ jsonrpc = '2.0', id = id, error = { code = -32600, message = 'invalid request' } })
    end
    local fn = methods[method]
    if not fn then
        return encode({ jsonrpc = '2.0', id = id, error = { code = -32601, message = 'method not found: ' .. tostring(method) } })
    end
    local ok, result = pcall(fn, params)
    if not ok then
        return encode({ jsonrpc = '2.0', id = id, error = { code = -32000, message = 'internal: ' .. tostring(result) } })
    end
    return encode({ jsonrpc = '2.0', id = id, result = result })
end

-- ---------------------------------------------------------------------------
-- Load event: bind listener
-- ---------------------------------------------------------------------------
ashita.register_event('load', function()
    trace('load event fired')
    if not ok_sock or not socket or type(socket.bind) ~= 'function' then
        trace('abort: socket lib not usable')
        return
    end
    local s, err = socket.bind(settings.host, settings.port, settings.backlog)
    trace('socket.bind => ' .. tostring(s) .. ' err=' .. tostring(err))
    if not s then
        print('[ai_bridge] bind failed: ' .. tostring(err))
        return
    end
    s:settimeout(0)
    state.listener = s
    state.running  = true
    trace('listening on ' .. settings.host .. ':' .. tostring(settings.port))
    print('[ai_bridge] listening on ' .. settings.host .. ':' .. tostring(settings.port))
end)

-- ---------------------------------------------------------------------------
-- Unload event: close sockets
-- ---------------------------------------------------------------------------
ashita.register_event('unload', function()
    trace('unload event')
    state.running = false
    if state.listener then pcall(function() state.listener:close() end); state.listener = nil end
    for _, c in ipairs(state.clients) do pcall(function() c.sock:close() end) end
    state.clients = {}
end)

-- ---------------------------------------------------------------------------
-- Render event: accept connections, pump I/O (non-blocking, every frame)
-- ---------------------------------------------------------------------------
ashita.register_event('render', function()
    if not state.running or not state.listener then return end

    -- Accept up to one new connection per frame
    if #state.clients < settings.max_clients then
        local nsock = state.listener:accept()
        if nsock then
            nsock:settimeout(0)
            state.clients[#state.clients+1] = { sock = nsock, buf = '' }
        end
    end

    -- Pump each client
    local keep = {}
    for _, c in ipairs(state.clients) do
        local alive = true
        -- read available data
        while true do
            local data, err, partial = c.sock:receive(1024)
            local chunk = data or partial
            if chunk and chunk ~= '' then
                c.buf = c.buf .. chunk
            end
            if not data then
                if err == 'closed' then alive = false end
                break -- timeout or closed
            end
        end
        -- Process full lines
        while true do
            local nl = c.buf:find('\n', 1, true)
            if not nl then break end
            local line = c.buf:sub(1, nl - 1)
            c.buf = c.buf:sub(nl + 1)
            -- strip \r
            line = line:gsub('\r$', '')
            if line ~= '' then
                local resp = handle_request(line)
                pcall(function() c.sock:send(resp .. '\n') end)
            end
        end
        if alive then keep[#keep+1] = c else pcall(function() c.sock:close() end) end
    end
    state.clients = keep
end)

-- ---------------------------------------------------------------------------
-- Optional: capture chat lines into tail buffer
-- ---------------------------------------------------------------------------
ashita.register_event('incoming_text', function(mode, text)
    if not text or text == '' then return false end
    state.chat_tail[#state.chat_tail+1] = { mode = mode, text = text, ts = os.time() }
    if #state.chat_tail > settings.chat_tail_max then
        table.remove(state.chat_tail, 1)
    end
    return false -- don't filter
end)

trace('--- ai_bridge top-level end ---')
