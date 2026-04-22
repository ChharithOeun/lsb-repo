--[[
ai_bridge - client-side FFXI state & control bridge for Chharbot / Claude.

This Ashita v3 addon runs inside the FFXI game process and opens a plain-TCP
JSON-RPC 2.0 listener on 127.0.0.1:27115. The mcp_ffxi_client MCP (see
mcp/ffxi_client/server.py) forwards MCP tool calls to this listener as
newline-delimited JSON requests.

Wire format: each request and each response is ONE line of JSON. Any message
without a trailing newline is buffered until the newline arrives.

Supported methods (minimum viable set):
  - get_state        { }         -> snapshot of player + target + zone
  - get_chat_tail    { n }       -> last N chat lines
  - get_entities     { radius }  -> entities within yalms
  - get_inventory    { bag }     -> items in bag (or all bags)
  - send_text        { text }    -> types into the chat input
  - target           { entity_id }
  - face             { yaw }
  - subscribe        { events }  -> server pushes event lines on same socket
  - ping             { }         -> health check

Notes:
  - Binds localhost only. Add a token in settings/settings.lua if you need auth.
  - Failure mode: if a listener call throws, the error is returned as JSON-RPC
    error and the addon keeps running. The socket is non-blocking so the
    game loop is never stalled.
  - Push events flow on the same connection that called `subscribe`; each
    event is its own JSON line starting with `{"event":"..."}`.
]]

addon.name      = 'ai_bridge'
addon.author    = 'Chharbot / Claude'
addon.version   = '0.1.0'
addon.desc      = 'Exposes FFXI client state and control to Chharbot over localhost JSON-RPC.'

require('common')
local chat   = require('chat')
local socket = require('socket')

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local default_settings = T{
    host    = '127.0.0.1',
    port    = 27115,
    token   = '',              -- if non-empty, clients must send {"auth":"<token>"} first
    backlog = 4,
    chat_tail_max = 200,
    max_clients   = 4,         -- DoS cap on concurrent connections
    rate_limit_n  = 30,        -- max calls per window
    rate_limit_w  = 1.0,       -- window seconds
    max_entities_radius = 50,  -- cap get_entities radius; prevent scan abuse
}

local settings = default_settings:copy(true)
do
    local ok, s = pcall(require, 'settings')
    if ok then
        settings = s.load(default_settings)
        s.register('settings', 'settings_update', function(v) settings:update(v, true) end)
    end
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local state = {
    listener  = nil,               -- server socket
    clients   = {},                -- array of { sock = ..., buf = '', subscribed = {event=true} }
    chat_tail = {},                -- ring buffer of recent chat lines
    running   = false,
}

-- JSON shim - Ashita ships a small json lib; fall back to a minimal encoder.
local json
do
    local ok, j = pcall(require, 'json')
    if ok then json = j end
end

local function encode(v) if json then return json.encode(v) end return tostring(v) end
local function decode(s) if json then return json.decode(s) end return nil end

-------------------------------------------------------------------------------
-- Helpers - read game state via Ashita APIs
-------------------------------------------------------------------------------
local function player_state()
    local party  = AshitaCore:GetMemoryManager():GetParty()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local ent    = AshitaCore:GetMemoryManager():GetEntity()

    local me_idx = party and party:GetMemberTargetIndex(0) or 0
    local me_x   = me_idx > 0 and ent:GetLocalPositionX(me_idx) or 0.0
    local me_y   = me_idx > 0 and ent:GetLocalPositionY(me_idx) or 0.0
    local me_z   = me_idx > 0 and ent:GetLocalPositionZ(me_idx) or 0.0

    local tgt_id = (AshitaCore:GetMemoryManager():GetTarget():GetServerId(0)) or 0

    return {
        name       = party and party:GetMemberName(0) or '?',
        zone_id    = party and party:GetMemberZone(0) or 0,
        hp         = party and party:GetMemberHP(0) or 0,
        hp_max     = party and party:GetMemberHPMax(0) or 0,
        mp         = party and party:GetMemberMP(0) or 0,
        mp_max     = party and party:GetMemberMPMax(0) or 0,
        tp         = party and party:GetMemberTP(0) or 0,
        main_job   = player and player:GetMainJob() or 0,
        sub_job    = player and player:GetSubJob() or 0,
        main_level = player and player:GetMainJobLevel() or 0,
        sub_level  = player and player:GetSubJobLevel() or 0,
        x          = me_x, y = me_y, z = me_z,
        target_id  = tgt_id,
    }
end

local function entities_within(radius)
    local ent = AshitaCore:GetMemoryManager():GetEntity()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local me_idx = party and party:GetMemberTargetIndex(0) or 0
    local ox = me_idx > 0 and ent:GetLocalPositionX(me_idx) or 0.0
    local oy = me_idx > 0 and ent:GetLocalPositionY(me_idx) or 0.0
    local oz = me_idx > 0 and ent:GetLocalPositionZ(me_idx) or 0.0
    local out = {}
    for i = 1, 2303 do
        local name = ent:GetName(i)
        if name and name ~= '' then
            local x = ent:GetLocalPositionX(i)
            local y = ent:GetLocalPositionY(i)
            local z = ent:GetLocalPositionZ(i)
            local dx, dy, dz = x - ox, y - oy, z - oz
            local d = math.sqrt(dx*dx + dy*dy + dz*dz)
            if d <= (radius or 30) then
                out[#out+1] = {
                    id   = ent:GetServerId(i),
                    idx  = i,
                    name = name,
                    type = ent:GetSpawnFlags(i),
                    hp_pct = ent:GetHPPercent(i),
                    x = x, y = y, z = z, dist = d,
                }
            end
        end
    end
    return out
end

local function inventory_items(bag)
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local res = AshitaCore:GetResourceManager()
    local out = {}
    local bags = bag and { bag } or { 0, 8, 10, 11, 12 } -- inventory + wardrobes
    for _, b in ipairs(bags) do
        local count = inv:GetContainerCountMax(b) or 0
        for i = 0, count - 1 do
            local it = inv:GetContainerItem(b, i)
            if it and it.Id and it.Id ~= 0 then
                local info = res:GetItemById(it.Id)
                out[#out+1] = {
                    bag   = b,
                    slot  = i,
                    item_id = it.Id,
                    name  = info and info.Name[1] or '?',
                    count = it.Count,
                }
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- JSON-RPC dispatch
-------------------------------------------------------------------------------
local methods = {}

methods.ping = function(_) return { pong = true, ts = os.time() } end

methods.get_state = function(_) return player_state() end

methods.get_chat_tail = function(params)
    local n = (params and params.n) or 20
    local first = math.max(1, #state.chat_tail - n + 1)
    local out = {}
    for i = first, #state.chat_tail do out[#out+1] = state.chat_tail[i] end
    return out
end

methods.get_entities = function(params)
    local r = (params and params.radius) or 30
    local cap = settings.max_entities_radius or 50
    if r > cap then r = cap end
    if r < 0 then r = 0 end
    return entities_within(r)
end

methods.get_inventory = function(params)
    return inventory_items(params and params.bag)
end

methods.send_text = function(params)
    if not params or type(params.text) ~= 'string' then
        error('text: string required')
    end
    local t = params.text
    if #t > 400 then error('text: too long (>400 chars)') end
    -- Strip CR/LF so a single send_text can't inject multiple chat lines.
    t = t:gsub('[\r\n]', ' ')
    AshitaCore:GetChatManager():QueueCommand(1, t)
    return { ok = true }
end

methods.target = function(params)
    if not params or not params.entity_id then error('entity_id required') end
    -- Ashita's target manager accepts server id or index; use /ta for simplicity.
    AshitaCore:GetChatManager():QueueCommand(1, ('/ta <t> %s'):format(tostring(params.entity_id)))
    return { ok = true }
end

methods.face = function(params)
    if not params or not params.yaw then error('yaw required') end
    -- Facing requires memory write; stubbed out - returns ok without acting.
    return { ok = true, stub = true }
end

methods.subscribe = function(params, client)
    local events = params and params.events or { 'chat' }
    client.subscribed = client.subscribed or {}
    for _, ev in ipairs(events) do client.subscribed[ev] = true end
    return { ok = true, events = events }
end

-------------------------------------------------------------------------------
-- Connection handling
-------------------------------------------------------------------------------
local function send_line(client, obj)
    local line = encode(obj) .. '\n'
    local ok, err = client.sock:send(line)
    if not ok then
        client.dead = true
    end
end

local function rate_limited(client)
    local now = os.time()
    local w = settings.rate_limit_w or 1.0
    if (now - (client.rl_window_start or now)) >= w then
        client.rl_window_start = now
        client.rl_count = 0
    end
    client.rl_count = (client.rl_count or 0) + 1
    return client.rl_count > (settings.rate_limit_n or 30)
end


local function handle_request(client, req)
    local rid = req.id
    -- Handshake: `{"auth":"<token>"}` is allowed as a standalone message
    -- before any method call. Everything else requires `authed`.
    if req.auth ~= nil then
        if settings.token == '' then
            client.authed = true
            send_line(client, { jsonrpc = '2.0', id = rid, result = { ok = true, note = 'no token configured' } })
        elseif req.auth == settings.token then
            client.authed = true
            send_line(client, { jsonrpc = '2.0', id = rid, result = { ok = true } })
        else
            send_line(client, { jsonrpc = '2.0', id = rid,
                error = { code = -32002, message = 'invalid token' } })
            client.dead = true
        end
        return
    end
    if not client.authed then
        send_line(client, { jsonrpc = '2.0', id = rid,
            error = { code = -32001, message = 'unauthenticated: send {"auth":"<token>"} first' } })
        return
    end
    if rate_limited(client) then
        send_line(client, { jsonrpc = '2.0', id = rid,
            error = { code = -32098, message = 'rate limited' } })
        return
    end
    local m = methods[req.method]
    if not m then
        send_line(client, { jsonrpc = '2.0', id = rid,
            error = { code = -32601, message = 'Method not found: ' .. tostring(req.method) } })
        return
    end
    local ok, res = pcall(m, req.params, client)
    if ok then
        send_line(client, { jsonrpc = '2.0', id = rid, result = res })
    else
        send_line(client, { jsonrpc = '2.0', id = rid,
            error = { code = -32000, message = tostring(res) } })
    end
end

local function process_buffer(client)
    while true do
        local nl = client.buf:find('\n', 1, true)
        if not nl then return end
        local line = client.buf:sub(1, nl - 1)
        client.buf = client.buf:sub(nl + 1)
        line = line:gsub('\r$', '')
        if #line > 0 then
            local ok, req = pcall(decode, line)
            if ok and type(req) == 'table' then
                handle_request(client, req)
            else
                send_line(client, { jsonrpc = '2.0', id = nil,
                    error = { code = -32700, message = 'Parse error' } })
            end
        end
    end
end

local function poll_clients()
    local i = 1
    while i <= #state.clients do
        local c = state.clients[i]
        c.sock:settimeout(0)
        local data, err, partial = c.sock:receive(4096)
        if data then
            c.buf = c.buf .. data
            process_buffer(c)
        elseif err == 'timeout' and partial and #partial > 0 then
            c.buf = c.buf .. partial
            process_buffer(c)
        elseif err == 'closed' then
            c.dead = true
        end
        if c.dead then
            pcall(function() c.sock:close() end)
            table.remove(state.clients, i)
        else
            i = i + 1
        end
    end
end

local function accept_clients()
    if not state.listener then return end
    state.listener:settimeout(0)
    local sock, err = state.listener:accept()
    while sock do
        sock:settimeout(0)
        if #state.clients >= (settings.max_clients or 4) then
            -- DoS protection: refuse new connections once the cap is hit.
            pcall(function()
                sock:send('{"jsonrpc":"2.0","id":null,"error":{"code":-32099,"message":"too many clients"}}\n')
                sock:close()
            end)
            print(chat.header(addon.name) ..
                  chat.warning('refused: max_clients reached'))
        else
            state.clients[#state.clients+1] = {
                sock = sock, buf = '', subscribed = {},
                authed = (settings.token == ''),   -- no auth needed iff no token configured
                rl_count = 0, rl_window_start = os.time(),
            }
            if settings.token == '' then
                print(chat.header(addon.name) .. chat.warning(
                    'client connected UNAUTHENTICATED (set settings.token to require auth)'))
            else
                print(chat.header(addon.name) .. chat.message('client connected; awaiting auth'))
            end
        end
        sock, err = state.listener:accept()
    end
end

local function broadcast_event(ev, payload)
    local line = encode(setmetatable({ event = ev, unpack = nil }, { __index = payload })) .. '\n'
    -- simpler: build merged table
    local merged = { event = ev }
    for k, v in pairs(payload or {}) do merged[k] = v end
    line = encode(merged) .. '\n'
    for _, c in ipairs(state.clients) do
        if c.subscribed and c.subscribed[ev] then
            local ok = pcall(function() c.sock:send(line) end)
            if not ok then c.dead = true end
        end
    end
end

-------------------------------------------------------------------------------
-- Chat tail capture
-------------------------------------------------------------------------------
local function push_chat(mode, text)
    state.chat_tail[#state.chat_tail+1] = {
        mode = mode, text = text, ts = os.time(),
    }
    while #state.chat_tail > settings.chat_tail_max do
        table.remove(state.chat_tail, 1)
    end
    broadcast_event('chat', { mode = mode, text = text })
end

-------------------------------------------------------------------------------
-- Ashita hooks
-------------------------------------------------------------------------------
ashita.events.register('load', 'ai_bridge_load', function()
    local sock, err = socket.bind(settings.host, settings.port, settings.backlog)
    if not sock then
        print(chat.header(addon.name) .. chat.error('bind failed: ' .. tostring(err)))
        return
    end
    sock:settimeout(0)
    state.listener = sock
    state.running  = true
    print(chat.header(addon.name) .. chat.message(
        ('listening on %s:%d'):format(settings.host, settings.port)))
end)

ashita.events.register('unload', 'ai_bridge_unload', function()
    state.running = false
    for _, c in ipairs(state.clients) do pcall(function() c.sock:close() end) end
    state.clients = {}
    if state.listener then pcall(function() state.listener:close() end) end
    state.listener = nil
end)

ashita.events.register('d3d_present', 'ai_bridge_tick', function()
    if not state.running then return end
    accept_clients()
    poll_clients()
end)

ashita.events.register('text_in', 'ai_bridge_text_in', function(e)
    push_chat(e.mode, e.message_modified or e.message)
end)

ashita.events.register('command', 'ai_bridge_cmd', function(e)
    local args = e.command:args()
    if #args == 0 or (args[1] ~= '/aibridge' and args[1] ~= '/aib') then return end
    e.blocked = true
    if args[2] == 'status' then
        print(chat.header(addon.name) .. chat.message(
            ('clients=%d chat_tail=%d'):format(#state.clients, #state.chat_tail)))
    elseif args[2] == 'kick' then
        for _, c in ipairs(state.clients) do c.dead = true end
        print(chat.header(addon.name) .. chat.message('kicked all clients'))
    else
        print(chat.header(addon.name) .. chat.message('commands: status | kick'))
    end
end)
