-- Windows backend: user32 via FFI.
local ffi = require("ffi")
local bit = require("bit")
local util = require("cinezoom.platform.ffi_util")
local null = require("cinezoom.platform.null")

local M = {}

M.cdef = [[
typedef struct cz_POINT { int32_t x; int32_t y; } cz_POINT;
int GetCursorPos(cz_POINT* p);
int16_t GetAsyncKeyState(int vKey);
int GetSystemMetrics(int index);
]]

-- Keys polled for typing activity: backspace, enter, space, 0-9, A-Z
local KEYS = { 0x08, 0x0D, 0x20 }
for vk = 0x30, 0x39 do KEYS[#KEYS + 1] = vk end
for vk = 0x41, 0x5A do KEYS[#KEYS + 1] = vk end

local SM_SWAPBUTTON = 23

function M.new()
    local ok, err = util.define("windows", M.cdef)
    if not ok then
        return null.new("could not declare Windows API: " .. tostring(err))
    end

    local symbols = {}
    local resolve = util.resolver(util.load_all({ "user32" }), symbols)
    local GetCursorPos = resolve("GetCursorPos")
    local GetAsyncKeyState = resolve("GetAsyncKeyState")
    local GetSystemMetrics = resolve("GetSystemMetrics")

    local point = ffi.new("cz_POINT[1]")
    local backend = { name = "windows", ok = GetCursorPos ~= nil, symbols = symbols }
    if not backend.ok then
        backend.reason = "GetCursorPos not found"
    end

    local clicks, keys = 0, 0
    local left_was_down = false
    local key_was_down = {}

    function backend.mouse()
        if GetCursorPos and GetCursorPos(point) ~= 0 then
            return point[0].x, point[0].y
        end
        return nil
    end

    -- Windows has no per-display query here; the display name parse is the lookup
    function backend.displays() return nil end

    function backend.buttons()
        if not GetAsyncKeyState then
            return false, nil
        end
        -- With swapped buttons the physical left button is VK_RBUTTON (0x02)
        local swapped = GetSystemMetrics and GetSystemMetrics(SM_SWAPBUTTON) ~= 0
        local down = bit.band(GetAsyncKeyState(swapped and 0x02 or 0x01), 0x8000) ~= 0
        if down and not left_was_down then
            clicks = clicks + 1
        end
        left_was_down = down
        return down, clicks
    end

    function backend.key_activity()
        if not GetAsyncKeyState then
            return nil
        end
        for _, vk in ipairs(KEYS) do
            local down = bit.band(GetAsyncKeyState(vk), 0x8000) ~= 0
            if down and not key_was_down[vk] then
                keys = keys + 1
            end
            key_was_down[vk] = down
        end
        return keys
    end

    function backend.close() end

    return backend
end

return M
