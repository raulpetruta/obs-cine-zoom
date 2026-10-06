-- Optional OBS API: a name that may be missing in this OBS version. Real obslua answers nil for an
-- unknown name, the test stub throws, so the read goes through pcall.
local obs = obslua

---
---@param name string Constant or function name in obslua
---@return any value, or nil when it does not exist
return function(name)
    local ok, v = pcall(function() return obs[name] end)
    return ok and v or nil
end
