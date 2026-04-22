--[[
xiloader_fixed default settings.lua
-----------------------------------
Edit values below and re-run /xilfix save in-game, or use /xilfix set
<k> <v> at the console. Boolean fields accept true/false.
--]]

return T{
    -- Path to the xiloader 2.1.x binary (the 1,072,128-byte build).
    xiloader  = 'F:\\ffxi\\Ashita\\ffxi-bootmod\\pol.exe',

    -- LSB xi_connect target. Leave 127.0.0.1 for self-hosted.
    server    = '127.0.0.1',

    -- Account credentials for autologin. The default guest pair below
    -- assumes the server-side accounts.password was re-hashed via
    -- UPDATE accounts SET password = PASSWORD('guestpass') ...
    user      = 'GUESTCL1',
    pass      = 'guestpass',

    -- Pass --hairpin so xiloader rewrites the public IP that LSB hands
    -- back into 127.0.0.1, which fixes NAT loopback when the client and
    -- server are on the same box. Leave true unless you've configured
    -- proper hairpin NAT on your router.
    hairpin   = true,

    -- Pass --hide so xiloader doesn't pop a console window. Set to
    -- false while debugging the handshake — the live xiloader console
    -- is the easiest place to see what went wrong.
    hide      = true,

    -- Run xiloader automatically on addon load. Set false if you want
    -- to fire it manually with /xilfix run.
    autostart = true,

    -- Milliseconds to wait after addon load before firing xiloader.
    -- Gives Ashita's main loop a tick to settle. Increase if you see
    -- "POL login prompt appears" in the troubleshooting section.
    delay_ms  = 250,
}
