-- Linux backend: libX11 via FFI. Works for X11 sessions and for XWayland.
-- The real Wayland pointer is not reachable this way (needs a native plugin).
local ffi = require("ffi")
local bit = require("bit")
local util = require("cinezoom.platform.ffi_util")
local null = require("cinezoom.platform.null")

local M = {}

M.cdef = [[
typedef unsigned long cz_XID;
typedef cz_XID cz_Window;
typedef void cz_Display;
cz_Display* XOpenDisplay(const char* name);
cz_XID XDefaultRootWindow(cz_Display* d);
int XQueryPointer(cz_Display* d, cz_Window w, cz_Window* root, cz_Window* child,
    int* root_x, int* root_y, int* win_x, int* win_y, unsigned int* mask);
int XCloseDisplay(cz_Display* d);
int XQueryKeymap(cz_Display* d, char* keys);
]]

function M.new()
    local wayland = (os.getenv("XDG_SESSION_TYPE") == "wayland") or (os.getenv("WAYLAND_DISPLAY") ~= nil)
    local wayland_note = wayland and
        "Wayland session detected: the mouse is only visible over XWayland windows, follow may not work" or nil

    local ok, err = util.define("x11", M.cdef)
    if not ok then
        return null.new("could not declare X11 API: " .. tostring(err))
    end

    local libs = util.load_all({ "libX11.so.6", "libX11.so", "X11" })
    if #libs == 0 then
        return null.new(wayland_note or "libX11 could not be loaded")
    end

    local symbols = {}
    local resolve = util.resolver(libs, symbols)
    local XOpenDisplay = resolve("XOpenDisplay")
    local XDefaultRootWindow = resolve("XDefaultRootWindow")
    local XQueryPointer = resolve("XQueryPointer")
    local XCloseDisplay = resolve("XCloseDisplay")
    local XQueryKeymap = resolve("XQueryKeymap")
    if not (XOpenDisplay and XDefaultRootWindow and XQueryPointer) then
        return null.new("required X11 symbols not found")
    end

    local okd, display = pcall(XOpenDisplay, nil)
    if not okd or display == nil then
        return null.new(wayland_note or "could not open the X11 display (is DISPLAY set?)")
    end

    local root = XDefaultRootWindow(display)
    local q = {
        root = ffi.new("cz_Window[1]"), child = ffi.new("cz_Window[1]"),
        root_x = ffi.new("int[1]"), root_y = ffi.new("int[1]"),
        win_x = ffi.new("int[1]"), win_y = ffi.new("int[1]"),
        mask = ffi.new("unsigned int[1]"),
    }
    local keymap = ffi.new("char[32]")
    local prev_keymap = ffi.new("uint8_t[32]")
    local keys, clicks = 0, 0
    local left_was_down = false

    local backend = { name = "x11", ok = true, reason = wayland_note, symbols = symbols }

    local function query()
        if display == nil then
            return false
        end
        return XQueryPointer(display, root, q.root, q.child, q.root_x, q.root_y, q.win_x, q.win_y, q.mask) ~= 0
    end

    function backend.mouse()
        if query() then
            return tonumber(q.root_x[0]), tonumber(q.root_y[0])
        end
        return nil
    end

    -- xshm_input names carry "WxH @ x,y", so the name parse is the display lookup
    function backend.displays() return nil end

    function backend.buttons()
        if not query() then
            return false, nil
        end
        local down = bit.band(q.mask[0], 256) ~= 0 -- Button1Mask
        if down and not left_was_down then
            clicks = clicks + 1
        end
        left_was_down = down
        return down, clicks
    end

    function backend.key_activity()
        if not XQueryKeymap or display == nil then
            return nil
        end
        XQueryKeymap(display, keymap)
        local changed = false
        for i = 0, 31 do
            local now = ffi.cast("uint8_t*", keymap)[i]
            -- a bit that is set now but was not before is a new key press
            if bit.band(now, bit.bnot(prev_keymap[i])) ~= 0 then
                changed = true
            end
            prev_keymap[i] = now
        end
        if changed then
            keys = keys + 1
        end
        return keys
    end

    function backend.close()
        if display ~= nil and XCloseDisplay then
            pcall(XCloseDisplay, display)
            display = nil
        end
    end

    return backend
end

return M
