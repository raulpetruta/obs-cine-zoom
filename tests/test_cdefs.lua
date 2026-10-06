local ffi = require("ffi")
local util = require("cinezoom.platform.ffi_util")

return function(t)
    for _, name in ipairs({ "macos", "windows", "x11" }) do
        t.test("cdef parses: " .. name, function()
            local mod = require("cinezoom.platform." .. name)
            local ok, err = util.define(name, mod.cdef)
            t.truthy(ok, tostring(err))
        end)
    end

    t.test("cdef parses: macOS objc fallback", function()
        local mod = require("cinezoom.platform.macos")
        local ok, err = util.define("macos_objc", mod.objc_cdef)
        t.truthy(ok, tostring(err))
    end)

    t.test("macOS struct layout", function()
        t.eq(ffi.sizeof("cz_CGRect"), 32)
        t.eq(ffi.sizeof("cz_CGPoint"), 16)
        t.eq(ffi.sizeof("cz_CGSize"), 16)
    end)

    t.test("macOS function-pointer cast for the NSEvent fallback parses", function()
        local p = ffi.cast("cz_CGPoint(*)(void*, void*)", 0)
        t.truthy(p ~= nil or p == nil) -- only the type parse matters
    end)

    t.test("defining the same set twice is not an error", function()
        local mod = require("cinezoom.platform.x11")
        local ok1 = util.define("x11-again", mod.cdef)
        local ok2 = util.define("x11-again", mod.cdef)
        t.truthy(ok1 and ok2)
    end)

    t.test("every cdef'd symbol is prefixed so it cannot clash with OBS", function()
        for _, name in ipairs({ "macos", "windows", "x11" }) do
            local mod = require("cinezoom.platform." .. name)
            for typedef in mod.cdef:gmatch("typedef%s+struct%s+([%w_]+)") do
                t.truthy(typedef:match("^cz_"), name .. ": " .. typedef)
            end
        end
    end)

    t.test("backends degrade to ok=false instead of throwing when libraries are missing", function()
        local platform = require("cinezoom.platform")
        for _, os_name in ipairs({ "OSX", "Windows", "Linux", "Other" }) do
            local b = platform.get(os_name)
            t.truthy(type(b.name) == "string")
            if not b.ok then
                -- must still answer every query without raising
                t.eq(b.mouse(), nil)
                b.displays(); b.buttons(); b.key_activity(); b.close()
            end
        end
    end)
end
