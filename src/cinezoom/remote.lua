-- Optional remote mouse listener: a UDP socket that receives "x y" text messages from a
-- companion app (https://github.com/BlankSourceCode/obs-zoom-to-mouse-remote).
-- Needs the ljsocket library; without it the feature is simply unavailable.
local log = require("cinezoom.log")

local M = {}

local available, socket = pcall(require, "ljsocket")
M.available = available

---
---@return table remote
function M.new()
    return { server = nil, mouse = nil, last_poll = 0 }
end

function M.start(r, port)
    if not available or r.server then
        return false
    end
    local ok, err = pcall(function()
        local address = socket.find_first_address("*", port)
        local server = socket.create("inet", "dgram", "udp")
        if server == nil then
            error("could not create the socket")
        end
        server:set_option("reuseaddr", 1)
        server:set_blocking(false)
        server:bind(address, port)
        r.server = server
    end)
    if not ok then
        log.warn("Could not start the remote mouse listener on port %s: %s", tostring(port), tostring(err))
        return false
    end
    log.info("Remote mouse listener on port %d", port)
    return true
end

function M.stop(r)
    if r.server ~= nil then
        log.info("Remote mouse listener stopped")
        pcall(function() r.server:close() end)
        r.server = nil
        r.mouse = nil
    end
end

---
-- Read every pending datagram; the latest position wins
function M.poll(r)
    if not r.server then
        return
    end
    repeat
        local okr, data, status = pcall(function() return r.server:receive_from() end)
        if not okr then
            log.warn("Remote mouse listener error: %s", tostring(data))
            return
        end
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                if not r.mouse then
                    log.info("Remote mouse client connected")
                end
                r.mouse = { x = tonumber(sx, 10), y = tonumber(sy, 10) }
            end
        elseif status ~= "timeout" and status ~= nil then
            log.warn("Remote mouse listener: %s", tostring(status))
        end
    until data == nil
end

return M
