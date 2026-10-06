-- Backend used when no real one is available: every query returns nil,
-- so the script keeps running (zoom by hotkey still works, following does not).
local M = {}

function M.new(reason)
    return {
        name = "null",
        ok = false,
        reason = reason or "no mouse backend for this platform",
        symbols = {},
        mouse = function() return nil end,
        displays = function() return nil end,
        buttons = function() return false, nil end,
        key_activity = function() return nil end,
        close = function() end,
    }
end

return M
