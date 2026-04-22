-- Default settings for the ai_bridge addon. Override per-character by
-- copying this file to settings/<charname>.lua and editing.
return T{
    -- Where to bind the JSON-RPC listener. Keep this on 127.0.0.1; the
    -- MCP wrapper runs on the same machine. Exposing it to the LAN is
    -- explicitly unsupported.
    host = '127.0.0.1',
    port = 27115,

    -- If non-empty, clients must send {"auth":"<token>"} as their first
    -- line before any method calls will be accepted. Blank = no auth,
    -- which is fine for localhost-only.
    token = '',

    -- How many unaccepted connections the OS should queue.
    backlog = 4,

    -- Max chat lines to retain for get_chat_tail.
    chat_tail_max = 200,
}
