-- Picks the mouse backend for the current OS.
local M = {}

local override = nil
local override_os = nil

---
-- Tests (and the smoke test) can force a backend table or a constructor,
-- and optionally pretend to run on another OS (ffi.os names: "OSX", "Windows", "Linux")
---@param b table|function|nil
---@param os_name string|nil
function M.set_override(b, os_name)
    override = b
    override_os = os_name
end

---
-- The OS name (ffi.os) the script is running on
---@return string
function M.os_name()
    if override_os then
        return override_os
    end
    local okf, ffi = pcall(require, "ffi")
    return okf and ffi.os or "Other"
end

---
-- Create the backend for the running platform
---@param os_name string|nil Defaults to ffi.os
---@return table backend
function M.get(os_name)
    if override ~= nil then
        return type(override) == "function" and override() or override
    end

    os_name = os_name or M.os_name()

    local mod
    if os_name == "OSX" then
        mod = "cinezoom.platform.macos"
    elseif os_name == "Windows" then
        mod = "cinezoom.platform.windows"
    elseif os_name == "Linux" then
        mod = "cinezoom.platform.x11"
    else
        mod = "cinezoom.platform.null"
    end

    local okm, backend = pcall(function() return require(mod).new() end)
    if okm and backend then
        return backend
    end
    return require("cinezoom.platform.null").new("backend failed to initialise: " .. tostring(backend))
end

return M
