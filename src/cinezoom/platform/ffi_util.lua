-- Small helpers shared by the FFI backends. Every cdef and every symbol lookup goes
-- through pcall so a missing library or symbol can never take the whole script down.
local ffi = require("ffi")

local M = {}

local defined = {}

---
-- ffi.cdef inside a pcall. Declaring the same set twice is treated as success
-- (LuaJIT raises "attempt to redefine" for typedefs it already knows).
---@param key string Name of the declaration set
---@param src string C declarations
---@return boolean ok, string|nil err
function M.define(key, src)
    if defined[key] ~= nil then
        return defined[key] == true, defined[key] ~= true and defined[key] or nil
    end
    local ok, err = pcall(ffi.cdef, src)
    if not ok and tostring(err):find("redefine", 1, true) then
        ok = true
    end
    defined[key] = ok or tostring(err)
    return ok, (not ok) and tostring(err) or nil
end

---
-- Try loading each candidate library name/path, returning the ones that load
---@param paths table List of library names or paths
---@return table libs
function M.load_all(paths)
    local libs = {}
    for _, path in ipairs(paths) do
        local ok, lib = pcall(ffi.load, path)
        if ok and lib ~= nil then
            libs[#libs + 1] = lib
        end
    end
    return libs
end

---
-- Build resolve(name): look the symbol up in ffi.C first, then in each loaded library.
-- Results (found or not) are recorded in `symbols` so Diagnose can list them.
---@param libs table
---@param symbols table
---@return function resolve
function M.resolver(libs, symbols)
    return function(name)
        local ok, fn = pcall(function() return ffi.C[name] end)
        if ok and fn ~= nil then
            symbols[name] = true
            return fn
        end
        for _, lib in ipairs(libs) do
            ok, fn = pcall(function() return lib[name] end)
            if ok and fn ~= nil then
                symbols[name] = true
                return fn
            end
        end
        symbols[name] = false
        return nil
    end
end

return M
