-- Bundles src/cinezoom/**/*.lua into the single file OBS loads (cinezoom.lua).
-- Each module becomes package.preload["cinezoom.x"] = function(...) <source> end, so the
-- script needs no sibling files at runtime.
--
--   luajit tools/bundle.lua            write cinezoom.lua
--   luajit tools/bundle.lua --check    exit 1 if the committed cinezoom.lua is out of date
--   luajit tools/bundle.lua --stdout   print the bundle
local M = {}

local HEADER = [[
-- OBSCineZoom for OBS Studio.
-- GENERATED FILE: do not edit. Sources are in src/cinezoom/, rebuild with `luajit tools/bundle.lua`.
-- MIT licensed, see LICENSE. Based on obs-zoom-to-mouse by BlankSourceCode (MIT).
]]

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

---
-- Module name for a source path: src/cinezoom/platform/init.lua -> cinezoom.platform
local function module_name(path)
    local name = path:gsub("^src/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
    return name
end

---
-- Build the bundle text
---@param root string Repository root
---@return string
function M.build(root)
    local files = {}
    local p = io.popen('cd "' .. root .. '" && find src -name "*.lua" | LC_ALL=C sort')
    for line in p:lines() do
        files[#files + 1] = line
    end
    p:close()
    assert(#files > 0, "no source files found under src/")

    local out = { HEADER }
    for _, path in ipairs(files) do
        local src = read(root .. "/" .. path):gsub("\r\n", "\n")
        if not src:match("\n$") then
            src = src .. "\n"
        end
        out[#out + 1] = string.format("package.preload[%q] = function(...)\n%send\n\n", module_name(path), src)
    end
    out[#out + 1] = 'require("cinezoom.main").install(_G)\n'
    return table.concat(out)
end

if arg and arg[0] and arg[0]:match("bundle%.lua$") then
    local root = (arg[0]:match("^(.*)/tools/bundle%.lua$")) or "."
    local text = M.build(root)
    local mode = arg[1]
    if mode == "--stdout" then
        io.write(text)
    elseif mode == "--check" then
        local f = io.open(root .. "/cinezoom.lua", "rb")
        local current = f and f:read("*a") or ""
        if f then f:close() end
        if current ~= text then
            io.stderr:write("cinezoom.lua is out of date, run: luajit tools/bundle.lua\n")
            os.exit(1)
        end
        print("cinezoom.lua is up to date")
    else
        local f = assert(io.open(root .. "/cinezoom.lua", "wb"))
        f:write(text)
        f:close()
        print("wrote cinezoom.lua (" .. #text .. " bytes)")
    end
end

return M
