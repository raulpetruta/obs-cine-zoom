local bundle = require("tools_bundle")

return function(t)
    t.test("bundle is deterministic", function()
        t.eq(bundle.build(t.root), bundle.build(t.root))
    end)

    t.test("committed cinezoom.lua is up to date", function()
        local f = io.open(t.root .. "/cinezoom.lua", "rb")
        t.truthy(f, "cinezoom.lua is missing, run: luajit tools/bundle.lua")
        local committed = f:read("*a")
        f:close()
        t.truthy(committed == bundle.build(t.root), "cinezoom.lua is out of date, run: luajit tools/bundle.lua")
    end)

    t.test("bundle compiles", function()
        t.truthy(loadstring(bundle.build(t.root), "=cinezoom.lua"))
    end)
end
