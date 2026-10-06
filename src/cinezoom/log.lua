-- Logging for OBSCineZoom.
-- info/warn/error ALWAYS print (so users see problems without enabling anything),
-- debug only prints when the "Enable debug logging" checkbox is on.
local M = {}

-- Values of OBS_LOG_ERROR / OBS_LOG_WARNING / OBS_LOG_INFO (used when the constants are missing)
local LEVELS = { error = 100, warn = 200, info = 300 }
local CONST = { error = "OBS_LOG_ERROR", warn = "OBS_LOG_WARNING", info = "OBS_LOG_INFO" }

M.debug_enabled = false
M.sink = nil -- optional function(level, msg) that replaces OBS output (used by tests)

local function emit(level, msg)
    if M.sink then
        return M.sink(level, msg)
    end
    local obs = rawget(_G, "obslua")
    if obs ~= nil and obs.script_log ~= nil then
        obs.script_log(obs[CONST[level]] or LEVELS[level], msg)
    end
end

local function format(fmt, ...)
    if select("#", ...) == 0 then
        return tostring(fmt)
    end
    local ok, s = pcall(string.format, fmt, ...)
    return ok and s or tostring(fmt)
end

function M.info(fmt, ...) emit("info", format(fmt, ...)) end
function M.warn(fmt, ...) emit("warn", "WARNING: " .. format(fmt, ...)) end
function M.error(fmt, ...) emit("error", "ERROR: " .. format(fmt, ...)) end

function M.debug(fmt, ...)
    if M.debug_enabled then
        emit("info", "[debug] " .. format(fmt, ...))
    end
end

---
-- Format a lua table into a readable string (keys sorted so output is stable)
---@param tbl table
---@param indent number|nil
---@return string
function M.dump(tbl, indent)
    indent = indent or 0
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local pad = string.rep("  ", indent + 1)
    local str = "{\n"
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            str = str .. pad .. tostring(k) .. " = " .. M.dump(v, indent + 1) .. ",\n"
        else
            str = str .. pad .. tostring(k) .. " = " .. tostring(v) .. ",\n"
        end
    end
    return str .. string.rep("  ", indent) .. "}"
end

return M
