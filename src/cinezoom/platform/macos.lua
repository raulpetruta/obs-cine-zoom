-- macOS backend: CoreGraphics / CoreFoundation through FFI.
--
-- Mouse position comes from CGEventGetLocation: global coordinates, origin at the
-- TOP-left of the main display, measured in points. That is the same space as
-- CGDisplayBounds, so no Y flipping is needed on the primary path.
-- The old NSEvent.mouseLocation path (bottom-left origin) is kept only as a fallback.
local ffi = require("ffi")
local util = require("cinezoom.platform.ffi_util")
local null = require("cinezoom.platform.null")

local M = {}

-- Struct return by value (CGPoint, CGRect) is handled by LuaJIT's FFI for these all-double structs.
M.cdef = [[
typedef struct cz_CGPoint { double x, y; } cz_CGPoint;
typedef struct cz_CGSize { double width, height; } cz_CGSize;
typedef struct cz_CGRect { cz_CGPoint origin; cz_CGSize size; } cz_CGRect;
void* CGEventCreate(void* source);
cz_CGPoint CGEventGetLocation(void* event);
void CFRelease(const void* cf);
int32_t CGGetActiveDisplayList(uint32_t max, uint32_t* ids, uint32_t* count);
uint32_t CGMainDisplayID(void);
cz_CGRect CGDisplayBounds(uint32_t d);
size_t CGDisplayPixelsWide(uint32_t d);
size_t CGDisplayPixelsHigh(uint32_t d);
void* CGDisplayCopyDisplayMode(uint32_t d);
size_t CGDisplayModeGetPixelWidth(void* m);
size_t CGDisplayModeGetPixelHeight(void* m);
void CGDisplayModeRelease(void* m);
void* CGDisplayCreateUUIDFromDisplayID(uint32_t d);
void* CFUUIDCreateString(void* alloc, void* uuid);
unsigned char CFStringGetCString(void* s, char* buf, long size, uint32_t enc);
bool CGEventSourceButtonState(int32_t state, uint32_t button);
uint32_t CGEventSourceCounterForEventType(int32_t state, uint32_t type);
]]

-- Only used by the fallback mouse path
M.objc_cdef = [[
typedef void* cz_SEL;
typedef void* cz_id;
typedef void* cz_Method;
cz_SEL sel_registerName(const char* str);
cz_id objc_getClass(const char* name);
cz_Method class_getClassMethod(cz_id cls, cz_SEL name);
void* method_getImplementation(cz_Method m);
]]

local FW = "/System/Library/Frameworks/%s.framework/%s"
-- These live in the dyld shared cache, so we must NOT check that the files exist on disk
local LIBS = {
    string.format(FW, "CoreGraphics", "CoreGraphics"),
    string.format(FW, "CoreFoundation", "CoreFoundation"),
    string.format(FW, "ApplicationServices", "ApplicationServices"),
    string.format(FW, "ColorSync", "ColorSync"),
    -- ColorSync is also reachable as a sub-framework of ApplicationServices
    "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ColorSync.framework/ColorSync",
}

local UTF8 = 0x08000100
local HID_SYSTEM_STATE = 1       -- kCGEventSourceStateHIDSystemState
local BUTTON_LEFT = 0            -- kCGMouseButtonLeft
local EVENT_LEFT_MOUSE_DOWN = 1  -- kCGEventLeftMouseDown
local EVENT_KEY_DOWN = 10        -- kCGEventKeyDown

function M.new()
    local ok, err = util.define("macos", M.cdef)
    if not ok then
        return null.new("could not declare CoreGraphics API: " .. tostring(err))
    end

    local symbols = {}
    local resolve = util.resolver(util.load_all(LIBS), symbols)

    local CGEventCreate = resolve("CGEventCreate")
    local CGEventGetLocation = resolve("CGEventGetLocation")
    local CFRelease = resolve("CFRelease")
    local CGGetActiveDisplayList = resolve("CGGetActiveDisplayList")
    local CGMainDisplayID = resolve("CGMainDisplayID")
    local CGDisplayBounds = resolve("CGDisplayBounds")
    local CGDisplayPixelsWide = resolve("CGDisplayPixelsWide")
    local CGDisplayPixelsHigh = resolve("CGDisplayPixelsHigh")
    local CGDisplayCopyDisplayMode = resolve("CGDisplayCopyDisplayMode")
    local CGDisplayModeGetPixelWidth = resolve("CGDisplayModeGetPixelWidth")
    local CGDisplayModeGetPixelHeight = resolve("CGDisplayModeGetPixelHeight")
    local CGDisplayModeRelease = resolve("CGDisplayModeRelease")
    local CGDisplayCreateUUIDFromDisplayID = resolve("CGDisplayCreateUUIDFromDisplayID")
    local CFUUIDCreateString = resolve("CFUUIDCreateString")
    local CFStringGetCString = resolve("CFStringGetCString")
    local CGEventSourceButtonState = resolve("CGEventSourceButtonState")
    local CGEventSourceCounterForEventType = resolve("CGEventSourceCounterForEventType")

    local backend = { name = "macos", symbols = symbols }

    ---------------------------------------------------------------- mouse
    local can_cg_mouse = CGEventCreate ~= nil and CGEventGetLocation ~= nil and CFRelease ~= nil

    local function main_display_height()
        if CGMainDisplayID and CGDisplayBounds then
            local okb, b = pcall(function() return CGDisplayBounds(CGMainDisplayID()).size.height end)
            if okb and b > 0 then return b end
        end
        if CGMainDisplayID and CGDisplayPixelsHigh then
            local okh, h = pcall(function() return tonumber(CGDisplayPixelsHigh(CGMainDisplayID())) end)
            if okh and h > 0 then return h end
        end
        return nil
    end

    -- Fallback: NSEvent.mouseLocation (bottom-left origin of the main display)
    local ns_mouse_location, ns_class, ns_sel
    do
        local okc = util.define("macos_objc", M.objc_cdef)
        local libs = okc and util.load_all({ "libobjc", "/usr/lib/libobjc.A.dylib" }) or {}
        if #libs > 0 then
            local oks = pcall(function()
                local lib = libs[1]
                ns_class = lib.objc_getClass("NSEvent")
                ns_sel = lib.sel_registerName("mouseLocation")
                local method = lib.class_getClassMethod(ns_class, ns_sel)
                if method ~= nil then
                    local imp = lib.method_getImplementation(method)
                    ns_mouse_location = ffi.cast("cz_CGPoint(*)(void*, void*)", imp)
                end
            end)
            if not oks then ns_mouse_location = nil end
            symbols["NSEvent.mouseLocation"] = ns_mouse_location ~= nil
        end
    end

    local cg_failed = false
    function backend.mouse()
        if can_cg_mouse and not cg_failed then
            local okm, x, y = pcall(function()
                local event = CGEventCreate(nil)
                if event == nil then
                    return nil
                end
                local p = CGEventGetLocation(event)
                local px, py = p.x, p.y
                CFRelease(event) -- CGEventCreate follows the Create rule: we own it
                return px, py
            end)
            if okm and x ~= nil then
                return x, y
            end
            if not okm then
                cg_failed = true -- stop retrying a call that throws, use the fallback
            end
        end

        if ns_mouse_location then
            local h = main_display_height()
            if h then
                local okn, x, y = pcall(function()
                    local p = ns_mouse_location(ns_class, ns_sel)
                    return p.x, h - p.y
                end)
                if okn then return x, y end
            end
        end
        return nil
    end

    ---------------------------------------------------------------- displays
    local function uuid_string(id)
        if not (CGDisplayCreateUUIDFromDisplayID and CFUUIDCreateString and CFStringGetCString and CFRelease) then
            return nil
        end
        local okp, result = pcall(function()
            local uuid = CGDisplayCreateUUIDFromDisplayID(id)
            if uuid == nil then
                return nil
            end
            local str = CFUUIDCreateString(nil, uuid)
            local out
            if str ~= nil then
                local buf = ffi.new("char[64]")
                if CFStringGetCString(str, buf, 64, UTF8) ~= 0 then
                    out = ffi.string(buf):upper()
                end
                CFRelease(str)
            end
            CFRelease(uuid)
            return out
        end)
        return okp and result or nil
    end

    local function pixel_size(id, fallback_w, fallback_h)
        if CGDisplayCopyDisplayMode and CGDisplayModeGetPixelWidth and CGDisplayModeGetPixelHeight then
            local okm, w, h = pcall(function()
                local mode = CGDisplayCopyDisplayMode(id)
                if mode == nil then
                    return nil
                end
                local pw, ph = tonumber(CGDisplayModeGetPixelWidth(mode)), tonumber(CGDisplayModeGetPixelHeight(mode))
                if CGDisplayModeRelease then
                    CGDisplayModeRelease(mode)
                elseif CFRelease then
                    CFRelease(mode)
                end
                return pw, ph
            end)
            if okm and w and w > 0 and h and h > 0 then
                return w, h
            end
        end
        if CGDisplayPixelsWide and CGDisplayPixelsHigh then
            local okp, w, h = pcall(function() return tonumber(CGDisplayPixelsWide(id)), tonumber(CGDisplayPixelsHigh(id)) end)
            if okp and w and w > 0 then
                return w, h
            end
        end
        return fallback_w, fallback_h
    end

    function backend.displays()
        if not (CGGetActiveDisplayList and CGDisplayBounds) then
            return nil
        end
        local okd, list = pcall(function()
            local ids = ffi.new("uint32_t[16]")
            local count = ffi.new("uint32_t[1]")
            if CGGetActiveDisplayList(16, ids, count) ~= 0 then
                return nil
            end
            local main_id = CGMainDisplayID and CGMainDisplayID() or nil
            local out = {}
            for i = 0, tonumber(count[0]) - 1 do
                local id = ids[i]
                local b = CGDisplayBounds(id)
                local w, h = b.size.width, b.size.height
                local pw, ph = pixel_size(id, w, h)
                out[#out + 1] = {
                    id = tonumber(id),
                    x = b.origin.x, y = b.origin.y, w = w, h = h,
                    px_w = pw, px_h = ph,
                    uuid = uuid_string(id),
                    main = main_id ~= nil and id == main_id,
                }
            end
            return out
        end)
        if okd then
            return list
        end
        return nil
    end

    ---------------------------------------------------------------- clicks / keys
    local counters_ok = CGEventSourceCounterForEventType ~= nil
    local edge_clicks, left_was_down = 0, false

    function backend.buttons()
        local down = false
        if CGEventSourceButtonState then
            local okb, v = pcall(CGEventSourceButtonState, HID_SYSTEM_STATE, BUTTON_LEFT)
            down = okb and v == true
        end

        -- Preferred: the system's own click counter. It cannot miss a click that
        -- starts and ends between two ticks.
        if counters_ok then
            local okc, n = pcall(CGEventSourceCounterForEventType, HID_SYSTEM_STATE, EVENT_LEFT_MOUSE_DOWN)
            if okc then
                return down, tonumber(n)
            end
            counters_ok = false
        end

        -- Fallback: count rising edges of the button state
        if down and not left_was_down then
            edge_clicks = edge_clicks + 1
        end
        left_was_down = down
        return down, edge_clicks
    end

    -- Needs the Input Monitoring permission on recent macOS; Diagnose reports whether it changes
    function backend.key_activity()
        if not CGEventSourceCounterForEventType then
            return nil
        end
        local okk, n = pcall(CGEventSourceCounterForEventType, HID_SYSTEM_STATE, EVENT_KEY_DOWN)
        if okk then
            return tonumber(n)
        end
        return nil
    end

    function backend.close() end

    backend.ok = can_cg_mouse or ns_mouse_location ~= nil
    if not backend.ok then
        backend.reason = "CoreGraphics and objc mouse functions could not be loaded"
    elseif not can_cg_mouse then
        backend.reason = "using the NSEvent fallback for the mouse (CoreGraphics functions missing)"
    end
    return backend
end

return M
