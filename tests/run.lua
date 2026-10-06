-- Test runner: luajit tests/run.lua
-- Every tests/test_*.lua file returns function(t) and registers cases with t.test(name, fn).
local root = (arg and arg[0] or ""):match("^(.*)/tests/run%.lua$") or "."
package.path = table.concat({
    root .. "/src/?.lua", root .. "/src/?/init.lua", root .. "/tests/?.lua", package.path,
}, ";")

local passed, failed = 0, 0
local current = ""

local t = { root = root }

function t.test(name, fn)
    local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s :: %s\n%s", current, name, err))
    end
end

function t.eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
    end
end

function t.near(a, b, tol, msg)
    if type(a) ~= "number" or math.abs(a - b) > tol then
        error(string.format("%s: expected %s +/- %s, got %s", msg or "near", tostring(b), tostring(tol), tostring(a)), 2)
    end
end

function t.truthy(v, msg)
    if not v then error(msg or "expected truthy value", 2) end
end

-- Collect test files in a stable order
local files = {}
local p = io.popen('ls "' .. root .. '/tests" | LC_ALL=C sort')
for name in p:lines() do
    if name:match("^test_.*%.lua$") then
        files[#files + 1] = name
    end
end
p:close()

for _, name in ipairs(files) do
    current = name
    local chunk, err = loadfile(root .. "/tests/" .. name)
    if not chunk then
        failed = failed + 1
        print("FAIL  " .. name .. " (load): " .. tostring(err))
    else
        local ok, e = xpcall(function() chunk()(t) end, debug.traceback)
        if not ok then
            failed = failed + 1
            print("FAIL  " .. name .. " (setup): " .. tostring(e))
        end
    end
end

print(string.format("%d passed, %d failed (%d test files)", passed, failed, #files))
os.exit(failed == 0 and 0 or 1)
