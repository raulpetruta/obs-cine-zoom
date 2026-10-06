-- OBS version parsing. The original script turned "30.1.2" into the float 30.1,
-- which made "30.10" and "30.1" indistinguishable. Here every part stays an integer.
local M = {}

---
-- Parse a version string such as "31.0.0-rc1" into integer parts
---@param s string
---@return table version {major, minor, patch} (all 0 if unparsable)
function M.parse(s)
    local a, b, c = tostring(s or ""):match("^%s*v?(%d+)%.?(%d*)%.?(%d*)")
    return {
        major = tonumber(a) or 0,
        minor = tonumber(b) or 0,
        patch = tonumber(c) or 0,
    }
end

---
-- True if version v (string or parsed table) is >= major.minor.patch
---@param v string|table
---@param major number
---@param minor number|nil
---@param patch number|nil
---@return boolean
function M.at_least(v, major, minor, patch)
    if type(v) == "string" then
        v = M.parse(v)
    end
    minor = minor or 0
    patch = patch or 0
    if v.major ~= major then return v.major > major end
    if v.minor ~= minor then return v.minor > minor end
    return v.patch >= patch
end

return M
