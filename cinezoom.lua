-- OBSCineZoom for OBS Studio.
-- GENERATED FILE: do not edit. Sources are in src/cinezoom/, rebuild with `luajit tools/bundle.lua`.
-- MIT licensed, see LICENSE. Based on obs-zoom-to-mouse by BlankSourceCode (MIT).
package.preload["cinezoom.assets.checksum"] = function(...)
-- CRC-32 (PNG chunks) and Adler-32 (zlib stream), pure Lua on LuaJIT's bit library.
-- Both return unsigned numbers and can be fed in pieces by passing the previous result back.
local bit = require("bit")

local M = {}

local TABLE = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then
            c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
        else
            c = bit.rshift(c, 1)
        end
    end
    TABLE[i] = c
end

local function unsigned(v)
    if v < 0 then
        v = v + 2 ^ 32
    end
    return v
end

---
-- CRC-32 (polynomial 0xEDB88320). Pass the previous result as `crc` to continue a checksum.
---@param s string
---@param crc number|nil
---@return number
function M.crc32(s, crc)
    local c = bit.bnot(crc or 0)
    for i = 1, #s do
        c = bit.bxor(TABLE[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return unsigned(bit.bnot(c))
end

---
-- Adler-32. Pass the previous result as `a` to continue a checksum.
---@param s string
---@param a number|nil
---@return number
function M.adler32(s, a)
    a = a or 1
    local s1, s2 = a % 65536, math.floor(a / 65536)
    for i = 1, #s do
        s1 = (s1 + s:byte(i)) % 65521
        s2 = (s2 + s1) % 65521
    end
    return s2 * 65536 + s1
end

return M
end

package.preload["cinezoom.assets.png"] = function(...)
-- Minimal PNG writer (8-bit RGBA, no compression: stored deflate blocks) and the ripple ring image.
-- OBS reads the file with its normal image loader, so the output only has to be a valid PNG.
local checksum = require("cinezoom.assets.checksum")

local M = {}

local SIGNATURE = "\137PNG\r\n\26\n"
local MAX_BLOCK = 65535

local function u32be(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256, v % 256)
end

local function chunk(kind, data)
    return u32be(#data) .. kind .. data .. u32be(checksum.crc32(data, checksum.crc32(kind)))
end

-- zlib stream made of stored (uncompressed) deflate blocks
local function zlib_stored(raw)
    local out = { "\120\1" } -- 0x78 0x01: deflate, 32K window, no preset dictionary, fastest level
    local n = #raw
    local pos = 1
    repeat
        local len = math.min(MAX_BLOCK, n - pos + 1)
        local final = (pos + len > n) and 1 or 0
        local nlen = 65535 - len
        out[#out + 1] = string.char(final, len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256))
        out[#out + 1] = raw:sub(pos, pos + len - 1)
        pos = pos + len
    until pos > n
    out[#out + 1] = u32be(checksum.adler32(raw))
    return table.concat(out)
end

---
-- Encode an image as PNG
---@param w number
---@param h number
---@param rgba string w*h*4 bytes, straight (non-premultiplied) alpha
---@return string
function M.encode(w, h, rgba)
    assert(#rgba == w * h * 4, "rgba must be w*h*4 bytes")
    local rows = {}
    local stride = w * 4
    for y = 0, h - 1 do
        rows[#rows + 1] = "\0" .. rgba:sub(y * stride + 1, (y + 1) * stride) -- filter type 0 (none)
    end
    local ihdr = u32be(w) .. u32be(h) .. "\8\6\0\0\0" -- 8 bit, RGBA, deflate, no filter, no interlace
    return SIGNATURE .. chunk("IHDR", ihdr) .. chunk("IDAT", zlib_stored(table.concat(rows))) .. chunk("IEND", "")
end

---
-- Anti-aliased ring, tex x tex pixels. The colour is the same everywhere (also where the
-- ring is transparent) so scaling the image never bleeds a different colour in.
---@param tex number Image size in pixels
---@param thick number Ring thickness in pixels (of the image)
---@return string rgba
function M.ring_rgba(tex, thick, r, g, b)
    local c = tex / 2
    local outer = tex / 2 - 1
    local inner = outer - thick
    local rgb = string.char(r, g, b)
    local out = {}
    for y = 0, tex - 1 do
        local dy = y + 0.5 - c
        for x = 0, tex - 1 do
            local dx = x + 0.5 - c
            local d = math.sqrt(dx * dx + dy * dy)
            local a = math.max(0, math.min(1, outer - d + 0.5)) * math.max(0, math.min(1, d - inner + 0.5))
            out[#out + 1] = rgb .. string.char(math.floor(a * 255 + 0.5))
        end
    end
    return table.concat(out)
end

return M
end

package.preload["cinezoom.assets.wav"] = function(...)
-- Mono 16-bit PCM WAV writer and the synthesized click sound.
local M = {}

local function u16le(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

---
-- Encode samples as a WAV file
---@param samples number[] Integers in -32768..32767
---@param rate number Samples per second
---@return string
function M.encode_pcm16(samples, rate)
    local n = #samples
    local body = {}
    for i = 1, n do
        local v = samples[i]
        if v < 0 then
            v = v + 65536
        end
        body[i] = u16le(v)
    end
    return table.concat({
        "RIFF", u32le(36 + n * 2), "WAVE",
        "fmt ", u32le(16), u16le(1), u16le(1), u32le(rate), u32le(rate * 2), u16le(2), u16le(16),
        "data", u32le(n * 2), table.concat(body),
    })
end

---
-- A short, crisp click: two sine partials and a burst of noise under a fast attack, 6 ms decay.
-- The noise is a fixed Park-Miller sequence so the file is identical on every run.
---@param rate number|nil Samples per second (default 48000)
---@return number[] samples Integers in -32768..32767
function M.click_samples(rate)
    rate = rate or 48000
    local n = math.floor(rate * 0.040)
    local x = 1
    local raw, peak = {}, 0
    for i = 0, n - 1 do
        local t = i / rate
        x = x * 16807 % 2147483647
        local noise = x / 2147483647 * 2 - 1
        local env = (1 - math.exp(-t / 0.0005)) * math.exp(-t / 0.006)
        local v = env * (0.55 * math.sin(2 * math.pi * 2400 * t) + 0.25 * math.sin(2 * math.pi * 5200 * t) + 0.2 * noise)
        raw[i + 1] = v
        peak = math.max(peak, math.abs(v))
    end
    local out = {}
    local gain = peak > 0 and 0.8 / peak or 0
    for i = 1, n do
        out[i] = math.floor(raw[i] * gain * 32767 + 0.5)
    end
    return out
end

return M
end

package.preload["cinezoom.autozoom"] = function(...)
-- Auto-zoom state machine (pure: no OBS, no clock of its own).
-- States:
--   out     fully zoomed out
--   in      zoomed in automatically; zooms out again after the idle timeout
--   manual  zoomed in by hotkey; stays until toggled
-- The caller feeds it one input per tick and applies the result {zoom, focus}.
local M = {}

M.DEFAULTS = {
    idle_timeout = 2.5,   -- seconds without activity before zooming out
    min_hold = 0.8,       -- never zoom out sooner than this after zooming in
    zoom_on_typing = false,
    zoom_out_on_fast = false,
    fast_speed = 2.0,     -- camera widths per second that count as "fast"
    typing_click_window = 10, -- typing zooms at the last click if it was this recent
}

---
---@param cfg table|nil Overrides for M.DEFAULTS
---@return table az
function M.new(cfg)
    local az = { cfg = {}, enabled = true }
    M.configure(az, cfg)
    M.reset(az)
    return az
end

function M.configure(az, cfg)
    for k, v in pairs(M.DEFAULTS) do
        az.cfg[k] = v
    end
    for k, v in pairs(cfg or {}) do
        az.cfg[k] = v
    end
    if cfg and cfg.enabled ~= nil then
        M.set_enabled(az, cfg.enabled)
    end
end

function M.reset(az)
    az.state = "out"
    az.since = 0
    az.last_activity = 0
    az.last_click = nil   -- {x, y, t}
    az.pending_focus = nil
    az.prev = nil         -- previous mouse sample for speed
end

---
-- Enable or disable the automatic behaviour. Disabling zooms out of an automatic zoom.
function M.set_enabled(az, on)
    az.enabled = on and true or false
    if not az.enabled and az.state == "in" then
        az.state = "out"
    end
end

---
-- Hotkey: zoom in (at focus = {x, y}) or out, overriding the automatic behaviour
---@param now number
---@param on boolean
---@param focus table|nil {x, y} camera-space position to zoom in on
function M.set_manual(az, now, on, focus)
    if on then
        az.state = "manual"
        az.since = now
        az.last_activity = now
        az.pending_focus = focus
    else
        az.state = "out"
        az.pending_focus = nil
    end
end

local function zoom_in(az, now, x, y)
    az.state = "in"
    az.since = now
    az.last_activity = now
    az.pending_focus = { x = x, y = y }
end

---
-- Advance the machine
---@param az table
---@param now number Seconds (any monotonic clock)
---@param input table {x, y, inside, clicks, left_down, keys, cam_w}
---   x, y     mouse in camera space (nil if unknown)
---   inside   mouse is within the captured area
---   clicks   number of left clicks since the last call
---   left_down  button currently held (drag)
---   keys     number of key presses since the last call
---   cam_w    camera width, to normalise the mouse speed
---@return table result {zoom = boolean, focus = {x, y}|nil}
function M.update(az, now, input)
    local cfg = az.cfg
    local has_pos = type(input.x) == "number" and type(input.y) == "number"
    local inside = has_pos and input.inside

    -- Mouse speed in camera widths per second
    local speed = 0
    if has_pos and az.prev and now > az.prev.t and (input.cam_w or 0) > 0 then
        local dx, dy = input.x - az.prev.x, input.y - az.prev.y
        speed = math.sqrt(dx * dx + dy * dy) / ((now - az.prev.t) * input.cam_w)
    end
    az.prev = has_pos and { x = input.x, y = input.y, t = now } or nil

    if az.enabled then
        -- Clicks outside the captured area are ignored
        if (input.clicks or 0) > 0 and inside then
            az.last_click = { x = input.x, y = input.y, t = now }
            if az.state == "out" then
                zoom_in(az, now, input.x, input.y)
            elseif az.state == "in" then
                az.last_activity = now
                az.pending_focus = { x = input.x, y = input.y } -- refocus
            end
        end

        -- A held button (drag) counts as continuous activity
        if input.left_down and inside and az.state == "in" then
            az.last_activity = now
        end

        if (input.keys or 0) > 0 then
            if az.state == "in" then
                az.last_activity = now
            elseif az.state == "out" and cfg.zoom_on_typing then
                -- The caret position is unknown, so use the last click if it is recent
                local c = az.last_click
                if c and now - c.t <= cfg.typing_click_window then
                    zoom_in(az, now, c.x, c.y)
                elseif inside then
                    zoom_in(az, now, input.x, input.y)
                end
            end
        end

        if az.state == "in" and now - az.since >= cfg.min_hold then
            if now - az.last_activity >= cfg.idle_timeout
                or (cfg.zoom_out_on_fast and speed > cfg.fast_speed) then
                az.state = "out"
                az.pending_focus = nil
            end
        end
    end

    local focus = az.pending_focus
    az.pending_focus = nil
    return { zoom = az.state ~= "out", focus = focus }
end

return M
end

package.preload["cinezoom.camera"] = function(...)
-- The virtual camera: springs on the view center and on log(zoom).
-- Animating log(zoom) makes zooming feel even (2x -> 4x takes as long as 1x -> 2x).
local spring = require("cinezoom.spring")
local geometry = require("cinezoom.geometry")

local M = {}

-- Spring stiffness presets (all critically damped)
M.PRESETS = { slow = 60, mellow = 120, quick = 220, rapid = 400 }

---
---@param cam_w number Camera space width (source pixels)
---@param cam_h number Camera space height
---@param k number|nil Spring stiffness
---@return table camera
function M.new(cam_w, cam_h, k)
    k = k or M.PRESETS.mellow
    return {
        w = cam_w,
        h = cam_h,
        cx = spring.new(cam_w / 2, k, 1, 0.05),
        cy = spring.new(cam_h / 2, k, 1, 0.05),
        lz = spring.new(0, k, 1, 1e-4),
    }
end

function M.set_stiffness(cam, k)
    cam.cx.k, cam.cy.k, cam.lz.k = k, k, k
end

---
-- Change the camera space size. Resets the camera to the full view.
function M.set_bounds(cam, w, h)
    cam.w, cam.h = w, h
    M.snap(cam, w / 2, h / 2, 1)
end

function M.set_target(cam, cx, cy, z)
    cam.cx.target = cx
    cam.cy.target = cy
    cam.lz.target = math.log(math.max(z or 1, 1))
end

function M.snap(cam, cx, cy, z)
    spring.snap(cam.cx, cx)
    spring.snap(cam.cy, cy)
    spring.snap(cam.lz, math.log(math.max(z or 1, 1)))
end

function M.step(cam, dt)
    spring.step(cam.cx, dt)
    spring.step(cam.cy, dt)
    spring.step(cam.lz, dt)
    -- Note: a settled spring snaps exactly onto its target, so zooming all the way out
    -- (target log(1) == 0) lands exactly on the full rect.
end

function M.zoom(cam)
    return math.exp(cam.lz.x)
end

---
-- The rectangle (in camera space) the camera currently shows
---@return table rect {x, y, w, h}
function M.rect(cam)
    return geometry.view_rect(cam.cx.x, cam.cy.x, M.zoom(cam), cam.w, cam.h)
end

function M.is_settled(cam)
    return spring.is_settled(cam.cx) and spring.is_settled(cam.cy) and spring.is_settled(cam.lz)
end

return M
end

package.preload["cinezoom.deadzone"] = function(...)
-- Follow behaviour: the camera stays put while the mouse is inside a rectangle around
-- the view center, and only moves when the mouse pushes against the edge of that rectangle.
local M = {}

---
-- Returns the new target center for the camera
---@param tx number Current target center x
---@param ty number Current target center y
---@param mx number Mouse x (camera space)
---@param my number Mouse y (camera space)
---@param view_w number Width of the zoomed view
---@param view_h number Height of the zoomed view
---@param frac number Deadzone size as a fraction (0-1) of half the view
---@return number x, number y
function M.apply(tx, ty, mx, my, view_w, view_h, frac)
    local lx = frac * view_w * 0.5
    local ly = frac * view_h * 0.5

    local dx = mx - tx
    if dx > lx then
        tx = mx - lx
    elseif dx < -lx then
        tx = mx + lx
    end

    local dy = my - ty
    if dy > ly then
        ty = my - ly
    elseif dy < -ly then
        ty = my + ly
    end

    return tx, ty
end

return M
end

package.preload["cinezoom.diagnose"] = function(...)
-- Diagnose: everything needed to debug a report, always logged (not gated by Debug).
-- Sections: Environment, Backend, Source, Displays, Live, Click effects, then a 5 second live probe.
local obs = obslua
local log = require("cinezoom.log")
local version = require("cinezoom.version")

local M = {}

M.PROBE_SAMPLES = 10
M.PROBE_SECONDS = 5

local probe = nil

local function fmt_num(v)
    return v ~= nil and string.format("%.1f", v) or "nil"
end

local function environment(ctx, lines)
    lines[#lines + 1] = "== Environment =="
    lines[#lines + 1] = "OBSCineZoom " .. tostring(ctx.version)
    lines[#lines + 1] = "OBS " .. tostring(ctx.obs_version)
    local okf, ffi = pcall(require, "ffi")
    if okf then
        lines[#lines + 1] = string.format("ffi.os=%s ffi.arch=%s", ffi.os, ffi.arch)
    else
        lines[#lines + 1] = "ffi unavailable"
    end
    local okj, jit = pcall(require, "jit")
    lines[#lines + 1] = "jit: " .. (okj and tostring(jit.version) or "unavailable")
    lines[#lines + 1] = string.format("legacy display_capture selectable: %s",
        tostring(not version.at_least(ctx.obs_version, 30)))
    local ovi_ok, w, h = pcall(function()
        local ovi = obs.obs_video_info()
        if obs.obs_get_video_info(ovi) then
            return ovi.base_width, ovi.base_height
        end
    end)
    lines[#lines + 1] = "canvas: " .. (ovi_ok and w and (w .. "x" .. h) or "unknown")
end

local function backend_section(ctx, lines)
    local b = ctx.backend
    lines[#lines + 1] = "== Backend =="
    lines[#lines + 1] = string.format("name=%s ok=%s reason=%s", b.name, tostring(b.ok), tostring(b.reason))
    local names = {}
    for name in pairs(b.symbols or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        parts[#parts + 1] = name .. "=" .. (b.symbols[name] and "yes" or "NO")
    end
    lines[#lines + 1] = "symbols: " .. (#parts > 0 and table.concat(parts, " ") or "(none)")
end

local function source_section(ctx, lines)
    lines[#lines + 1] = "== Source =="
    for _, l in ipairs(ctx.si:describe()) do
        lines[#lines + 1] = l
    end
end

local function displays_section(ctx, lines)
    lines[#lines + 1] = "== Displays =="
    local okd, list = pcall(ctx.backend.displays)
    if okd and list then
        for i, d in ipairs(list) do
            lines[#lines + 1] = string.format("[%d] id=%s %sx%s @ %s,%s pixels=%sx%s uuid=%s%s", i, tostring(d.id),
                fmt_num(d.w), fmt_num(d.h), fmt_num(d.x), fmt_num(d.y), fmt_num(d.px_w), fmt_num(d.px_h),
                tostring(d.uuid), d.main and " (main)" or "")
        end
    else
        lines[#lines + 1] = "backend lists no displays (the display name is parsed instead)"
    end
    local d = ctx.display
    if d then
        local sx = d.scale_x or (ctx.si.base_w > 0 and ctx.si.base_w / d.w) or nil
        local sy = d.scale_y or (ctx.si.base_h > 0 and ctx.si.base_h / d.h) or nil
        lines[#lines + 1] = string.format("matched: %sx%s @ %s,%s via %s, mouse->source scale %s x %s",
            fmt_num(d.w), fmt_num(d.h), fmt_num(d.x), fmt_num(d.y), tostring(d.method), fmt_num(sx), fmt_num(sy))
    else
        lines[#lines + 1] = "matched: NO DISPLAY (following is disabled). " .. tostring(ctx.display_note)
    end
end

local function sample_line(s)
    return string.format("mouse global=(%s,%s) source=(%s,%s) camera=(%s,%s) left=%s clicks=%s keys=%s",
        fmt_num(s.gx), fmt_num(s.gy), fmt_num(s.sx), fmt_num(s.sy), fmt_num(s.cx), fmt_num(s.cy),
        tostring(s.left), tostring(s.clicks), tostring(s.keys))
end

local function live_section(ctx, lines)
    lines[#lines + 1] = "== Live =="
    lines[#lines + 1] = sample_line(ctx.sample())
    lines[#lines + 1] = string.format("zoomed=%s following=%s auto=%s", tostring(ctx.state.zoomed),
        tostring(ctx.state.following), tostring(ctx.state.auto))
end

local function fx_section(ctx, lines)
    lines[#lines + 1] = "== Click effects =="
    if ctx.fx == nil then
        lines[#lines + 1] = "not available"
        return
    end
    local ok, fx_lines = pcall(ctx.fx.describe, ctx.fx, ctx.si)
    if not ok then
        lines[#lines + 1] = "could not describe the effects: " .. tostring(fx_lines)
        return
    end
    for _, l in ipairs(fx_lines) do
        lines[#lines + 1] = l
    end
end

---
-- Build the report
---@param ctx table See main.lua (diagnose_context)
---@return table lines
function M.report(ctx)
    local lines = {}
    environment(ctx, lines)
    backend_section(ctx, lines)
    source_section(ctx, lines)
    displays_section(ctx, lines)
    live_section(ctx, lines)
    fx_section(ctx, lines)
    return lines
end

---
-- Log the report and start the live probe (driven by M.tick from script_tick)
function M.run(ctx)
    local lines = M.report(ctx)
    log.info("---------------- OBSCineZoom Diagnose ----------------\n" .. table.concat(lines, "\n"))
    log.info("Live probe: move the mouse, click, and type for %d seconds...", M.PROBE_SECONDS)
    probe = { t = 0, n = 0, interval = M.PROBE_SECONDS / M.PROBE_SAMPLES, samples = {}, ctx = ctx }
end

function M.is_probing()
    return probe ~= nil
end

local function finish(p)
    local first, last = p.samples[1], p.samples[#p.samples]
    local function changed(a, b) return a ~= nil and b ~= nil and a ~= b end
    local verdict = {
        "Probe finished (" .. #p.samples .. " samples).",
        "mouse moved: " .. tostring(changed(first.gx, last.gx) or changed(first.gy, last.gy)),
        "click counter changed: " .. tostring(changed(first.clicks, last.clicks)),
        "key counter changed: " .. tostring(changed(first.keys, last.keys)) ..
            (first.keys == nil and " (no key counter on this platform)" or ""),
    }
    if first.keys ~= nil and not changed(first.keys, last.keys) then
        verdict[#verdict + 1] = "If you typed and the key counter did not change, grant OBS the Input Monitoring permission."
    end
    log.info(table.concat(verdict, "\n"))
    probe = nil
end

---
-- Advance the probe. Call from script_tick.
function M.tick(seconds)
    local p = probe
    if not p then
        return
    end
    p.t = p.t + seconds
    while p.t >= p.interval * (p.n + 1) and p.n < M.PROBE_SAMPLES do
        p.n = p.n + 1
        local s = p.ctx.sample()
        p.samples[#p.samples + 1] = s
        log.info("probe %d/%d: %s", p.n, M.PROBE_SAMPLES, sample_line(s))
    end
    if p.n >= M.PROBE_SAMPLES then
        finish(p)
    end
end

function M.cancel()
    probe = nil
end

return M
end

package.preload["cinezoom.effects"] = function(...)
-- Click effects controller: owns the generated asset files, the sound and the ripple.
-- Both effects are off by default, and nothing is created until one is switched on.
local log = require("cinezoom.log")
local png = require("cinezoom.assets.png")
local wav = require("cinezoom.assets.wav")
local sound_mod = require("cinezoom.effects.sound")
local ripple_mod = require("cinezoom.effects.ripple")

local M = {}

-- Test hook: when set, assets are written to this directory only
M.asset_dir = nil

local RING_TEX = 256 -- pixels of the generated ring image

local Fx = {}
Fx.__index = Fx

---
---@return table controller
function M.new()
    return setmetatable({ cfg = nil, sound = nil, ripple = nil, assets = {}, warned = {}, off = false }, Fx)
end

-- Directories to try for the generated files, best first. Temp comes before the script folder:
-- the files are disposable, and that folder may be read-only, synced or a git checkout.
local function candidate_dirs()
    if M.asset_dir ~= nil then
        return { M.asset_dir }
    end
    local dirs = {}
    for _, var in ipairs({ "TMPDIR", "TEMP", "TMP" }) do
        local v = os.getenv(var)
        if v ~= nil and v ~= "" then
            dirs[#dirs + 1] = v
        end
    end
    dirs[#dirs + 1] = "/tmp"
    local sp = rawget(_G, "script_path")
    if type(sp) == "function" then
        local ok, dir = pcall(sp)
        if ok and type(dir) == "string" and dir ~= "" then
            dirs[#dirs + 1] = dir
        end
    end
    return dirs
end

local function join(dir, name)
    if dir:match("[/\\]$") then
        return dir .. name
    end
    return dir .. "/" .. name
end

local function file_size(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local size = f:seek("end")
    f:close()
    return size
end

-- Path of a generated file, (re)written when it is missing or has the wrong size
function Fx:asset(name, make)
    local known = self.assets[name]
    if known ~= nil and file_size(known.path) == known.size then
        return known.path
    end
    local bytes = make()
    for _, dir in ipairs(candidate_dirs()) do
        local path = join(dir, name)
        local f = io.open(path, "wb")
        if f ~= nil then
            local okw = f:write(bytes)
            f:close()
            if okw then
                self.assets[name] = { path = path, size = #bytes }
                return path
            end
        end
    end
    return nil
end

-- A user-chosen file wins when it is readable, otherwise warn once and use the generated one
function Fx:custom(path)
    if path == nil or path == "" then
        return nil
    end
    if file_size(path) ~= nil then
        return path
    end
    if not self.warned[path] then
        self.warned[path] = true
        log.warn("Click effects: cannot read '%s', using the built-in file instead.", path)
    end
    return nil
end

function Fx:sound_path(sc)
    return self:custom(sc.file) or self:asset("cinezoom-click-v1.wav", function()
        return wav.encode_pcm16(wav.click_samples(48000), 48000)
    end)
end

-- Returns the ring image path and its width (nil for a custom image: OBS measures it)
function Fx:ripple_path(rc)
    local custom = self:custom(rc.file)
    if custom ~= nil then
        return custom, nil
    end
    local thick = math.max(1, math.floor(rc.thickness * RING_TEX / rc.size + 0.5))
    local col = rc.color -- 0xAABBGGRR: red is the low byte
    local r, g, b = col % 256, math.floor(col / 256) % 256, math.floor(col / 65536) % 256
    local name = string.format("cinezoom-ring-v1-%d-%d-%02x%02x%02x.png", RING_TEX, thick, r, g, b)
    return self:asset(name, function()
        return png.encode(RING_TEX, RING_TEX, png.ring_rgba(RING_TEX, thick, r, g, b))
    end), RING_TEX
end

---
-- Create, update or remove the parts to match the settings
---@param c table cfg.fx (see settings.lua)
function Fx:configure(c)
    self.cfg = c
    self.off = false

    if c.sound.enabled then
        local path = self:sound_path(c.sound)
        if path == nil then
            log.warn("Click sound is off: no folder is writable for the generated sound file.")
        else
            self.sound = self.sound or sound_mod.new()
            if not self.sound:configure(c.sound, path) then
                self.sound = nil
            end
        end
    elseif self.sound ~= nil then
        self.sound:destroy()
        self.sound = nil
    end

    if c.ripple.enabled then
        local path, tex = self:ripple_path(c.ripple)
        if path == nil then
            log.warn("Click ripple is off: no folder is writable for the generated ring image.")
        else
            self.ripple = self.ripple or ripple_mod.new()
            if not self.ripple:configure(c.ripple, path, tex) then
                self.ripple = nil
            end
        end
    elseif self.ripple ~= nil then
        self.ripple:destroy()
        self.ripple = nil
    end
end

---
-- True when an effect is switched on (and has not been turned off after errors)
function Fx:active()
    return not self.off and (self.sound ~= nil or self.ripple ~= nil)
end

---
-- A click was seen: at most one sound and one ripple per call. The caller applied the
-- "only inside" and "only while zoomed" filters to n. Errors are raised after both effects ran.
---@param n number Clicks since the last tick
---@param inside boolean The mouse is over the captured display
---@param cam_pt table|nil {x, y} mouse position in camera space
---@param si table Scene item controller
---@param now number
function Fx:on_click(n, inside, cam_pt, si, now)
    if n <= 0 or self.off then
        return
    end
    local err = nil
    if self.sound ~= nil then
        local ok, e = pcall(self.sound.play, self.sound)
        if not ok then err = e end
    end
    if self.ripple ~= nil and inside and cam_pt ~= nil and si.ready then
        local ok, e = pcall(function()
            if self.ripple:ensure_host(si) then
                self.ripple:spawn(cam_pt.x, cam_pt.y, now)
            end
        end)
        if not ok then err = err or e end
    end
    if err ~= nil then
        error(err, 0)
    end
end

---
-- Advance running ripples (every tick)
function Fx:tick(si, now)
    if self.ripple ~= nil and not self.off then
        self.ripple:update(si, now, si.cam_w)
    end
end

---
-- The "Test click effects" button: play the sound and show a ripple at cam_pt (the view center if nil)
---@return string message for the log
function Fx:test_click(cam_pt, si, now)
    if not self:active() then
        return "Turn on Click sound or Click ripple first."
    end
    local parts = {}
    if self.sound ~= nil then
        self.sound:play()
        parts[#parts + 1] = "played the click sound"
    end
    if self.ripple ~= nil then
        if si.ready and self.ripple:ensure_host(si) then
            local pt = cam_pt
            if pt == nil or pt.x < 0 or pt.y < 0 or pt.x > si.cam_w or pt.y > si.cam_h then
                pt = { x = si.cam_w / 2, y = si.cam_h / 2 }
                parts[#parts + 1] = "ripple at the center (the mouse is not over the zoom source)"
            else
                parts[#parts + 1] = "ripple at the mouse"
            end
            self.ripple:spawn(pt.x, pt.y, now)
        else
            parts[#parts + 1] = "no ripple (the zoom source is not ready)"
        end
    end
    return "Test click: " .. table.concat(parts, ", ")
end

---
-- Take the overlay item out of the scene it is in (the capture or scene is about to change)
function Fx:detach_host()
    if self.ripple ~= nil then
        local ok, err = pcall(self.ripple.detach_host, self.ripple)
        if not ok then
            log.debug("Click overlay detach failed: %s", tostring(err))
        end
    end
end

---
-- The scene collection is about to change (or OBS is closing): nothing of ours may stay in its scenes
function Fx:on_collection_changing()
    if self.ripple ~= nil then
        pcall(self.ripple.destroy, self.ripple)
        self.ripple = nil
    end
end

---
-- The new scene collection is loaded: bring back what OBS may have cleared
function Fx:on_collection_changed()
    if self.sound ~= nil then
        self.sound:reattach()
    end
    if self.cfg ~= nil and not self.off and self.cfg.ripple.enabled and self.ripple == nil then
        self:configure(self.cfg)
    end
end

-- Remove the generated files (never anything the user chose)
function Fx:remove_files()
    for _, a in pairs(self.assets) do
        pcall(os.remove, a.path)
    end
    self.assets = {}
end

---
-- Remove everything we created in OBS and on disk
function Fx:destroy()
    if self.ripple ~= nil then
        pcall(self.ripple.destroy, self.ripple)
        self.ripple = nil
    end
    if self.sound ~= nil then
        pcall(self.sound.destroy, self.sound)
        self.sound = nil
    end
    self:remove_files()
end

---
-- Turn the effects off after repeated errors (a settings change turns them on again)
function Fx:disable()
    self:destroy()
    self.off = true
end

---
---@param si table|nil scene item controller
---@return table lines for Diagnose
function Fx:describe(si)
    local lines = {}
    if self.sound == nil and self.ripple == nil then
        lines[#lines + 1] = self.off and "effects: turned off after errors (change a setting to try again)"
            or "effects: off (nothing created)"
    end
    local names = {}
    for name in pairs(self.assets) do
        names[#names + 1] = name
    end
    table.sort(names)
    if #names == 0 then
        lines[#lines + 1] = "asset directory: none used yet"
    end
    for _, name in ipairs(names) do
        local a = self.assets[name]
        local writable = false
        local f = io.open(a.path, "ab")
        if f ~= nil then
            writable = true
            f:close()
        end
        lines[#lines + 1] = string.format("asset: %s, %s bytes, writable: %s", a.path,
            tostring(file_size(a.path)), tostring(writable))
    end
    if self.sound ~= nil then
        for _, l in ipairs(self.sound:describe()) do lines[#lines + 1] = l end
    else
        lines[#lines + 1] = "sound: off"
    end
    if self.ripple ~= nil then
        for _, l in ipairs(self.ripple:describe(si)) do lines[#lines + 1] = l end
    else
        lines[#lines + 1] = "ripple: off"
    end
    lines[#lines + 1] = "The monitoring device is set in OBS Settings > Audio > Advanced."
    return lines
end

return M
end

package.preload["cinezoom.effects.pool"] = function(...)
-- Fixed-size slot pool (pure). A slot is a table {index, active, t0, seq}; the owner attaches its
-- own fields to it. Acquiring when every slot is busy takes over the oldest one.
local M = {}

local Pool = {}
Pool.__index = Pool

---
---@param n number Number of slots
---@return table pool
function M.new(n)
    local pool = setmetatable({ slots = {}, counter = 0 }, Pool)
    for i = 1, n do
        pool.slots[i] = { index = i, active = false, t0 = 0, seq = 0 }
    end
    return pool
end

---
-- A free slot, or the oldest active one when none is free
---@param now number
---@return table slot
function Pool:acquire(now)
    local pick = nil
    for _, s in ipairs(self.slots) do
        if not s.active then
            pick = s
            break
        end
        if pick == nil or s.seq < pick.seq then
            pick = s
        end
    end
    self.counter = self.counter + 1
    pick.active, pick.t0, pick.seq = true, now, self.counter
    return pick
end

function Pool:release(slot)
    slot.active = false
end

---
-- Call fn(slot) for every active slot
function Pool:each_active(fn)
    for _, s in ipairs(self.slots) do
        if s.active then
            fn(s)
        end
    end
end

function Pool:any_active()
    for _, s in ipairs(self.slots) do
        if s.active then
            return true
        end
    end
    return false
end

return M
end

package.preload["cinezoom.effects.ripple"] = function(...)
-- Click ripple: a ring image that grows and fades where you clicked.
-- Layout: one private overlay scene holds a pool of image slots (private image_source with a private
-- color filter for the fade). The overlay scene is added ONCE to the scene that holds the capture
-- item, directly above it, as a locked item at (0,0) with scale 1. Everything is private, so a saved
-- scene collection never contains our sources, and the item is removed on scene change, collection
-- change and unload.
local obs = obslua
local log = require("cinezoom.log")
local geometry = require("cinezoom.geometry")
local anim = require("cinezoom.effects.ripple_anim")
local pool_mod = require("cinezoom.effects.pool")

local M = {}

M.OVERLAY_NAME = "OBSCineZoom click effects"
M.SLOTS = 4

local get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local Ripple = {}
Ripple.__index = Ripple

---
---@return table ripple controller (creates nothing until configure)
function M.new()
    return setmetatable({
        overlay = nil,
        pool = nil,
        host = nil,       -- {item, id, name, grouped, order}: our item in the capture's scene
        cfg = nil,
        path = nil,
        tex_w = 0,
        fade = nil,       -- "v2", "v1" or "none" once decided
        blocked = false,  -- rotated capture: no ripple until the next attach
        last = nil,       -- last placement, for Diagnose
    }, Ripple)
end

local function bounds_constants()
    return {
        NONE = obs.OBS_BOUNDS_NONE, STRETCH = obs.OBS_BOUNDS_STRETCH, SCALE_INNER = obs.OBS_BOUNDS_SCALE_INNER,
        SCALE_OUTER = obs.OBS_BOUNDS_SCALE_OUTER, SCALE_TO_WIDTH = obs.OBS_BOUNDS_SCALE_TO_WIDTH,
        SCALE_TO_HEIGHT = obs.OBS_BOUNDS_SCALE_TO_HEIGHT, MAX_ONLY = obs.OBS_BOUNDS_MAX_ONLY,
    }
end

local function read_info(item)
    local info = obs.obs_transform_info()
    get_info(item, info)
    return info
end

local function scene_name(scene)
    return obs.obs_source_get_name(obs.obs_scene_get_source(scene))
end

-- Bottom-to-top index (0 = bottom) of an item in a scene, compared by id
local function index_of(scene, item)
    local want = obs.obs_sceneitem_get_id(item)
    local found = nil
    local list = obs.obs_scene_enum_items(scene)
    if list then
        for i, it in ipairs(list) do
            if obs.obs_sceneitem_get_id(it) == want then
                found = i - 1
                break
            end
        end
        obs.sceneitem_list_release(list)
    end
    return found
end

local function image_settings(path)
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "file", path)
    obs.obs_data_set_bool(s, "unload", false)
    return s
end

-- Create the opacity filter of a slot: color_filter_v2 (opacity 0..1), else color_filter (0..100)
local function add_fade(self, slot)
    local tries = { { id = "color_filter_v2", mode = "v2" }, { id = "color_filter", mode = "v1" } }
    for _, t in ipairs(tries) do
        if self.fade == nil or self.fade == t.mode then
            local fdata = obs.obs_data_create()
            if t.mode == "v2" then
                obs.obs_data_set_double(fdata, "opacity", 0.0)
            else
                obs.obs_data_set_int(fdata, "opacity", 0)
            end
            local f = obs.obs_source_create_private(t.id, "cz-ripple-opacity", fdata)
            if f ~= nil then
                obs.obs_source_filter_add(slot.img, f)
                slot.filter, slot.fdata, slot.op = f, fdata, nil
                self.fade = t.mode
                return
            end
            obs.obs_data_release(fdata)
        end
    end
    if self.fade == nil then
        self.fade = "none"
        log.warn("Click ripple: no opacity filter is available, the ripple will not fade out smoothly.")
    end
end

local function create_slot(self, slot, path)
    local s = image_settings(path)
    local img = obs.obs_source_create_private("image_source", "OBSCineZoom ripple " .. slot.index, s)
    obs.obs_data_release(s)
    if img == nil then
        error("could not create the image source", 0)
    end
    slot.img = img
    add_fade(self, slot)
    local item = obs.obs_scene_add(self.overlay, img)
    if item == nil then
        error("could not add the image to the overlay scene", 0)
    end
    obs.obs_sceneitem_addref(item)
    slot.item = item
    obs.obs_sceneitem_set_visible(item, false)
end

-- Size of the ring image in pixels (a custom image is measured, 0 if OBS does not know yet)
local function measure(self)
    local slot = self.pool and self.pool.slots[1]
    if slot and slot.img then
        local w = obs.obs_source_get_width(slot.img)
        if w and w > 0 then
            return w
        end
    end
    return 0
end

---
-- Create the overlay and slots on first use, or apply a changed image and settings.
---@param rc table ripple settings {size, duration, opacity (0..1), zoom_scale}
---@param path string Ring image
---@param tex_w number|nil Image width in pixels (nil: ask OBS)
---@return boolean ok
function Ripple:configure(rc, path, tex_w)
    self.cfg = rc
    local ok, err = pcall(function()
        if self.overlay == nil then
            self.B = bounds_constants()
            self.overlay = obs.obs_scene_create_private(M.OVERLAY_NAME)
            if self.overlay == nil then
                error("could not create the overlay scene", 0)
            end
            self.pool = pool_mod.new(M.SLOTS)
            self.fade = nil
            for _, slot in ipairs(self.pool.slots) do
                create_slot(self, slot, path)
            end
            self.path = path
        elseif path ~= self.path then
            for _, slot in ipairs(self.pool.slots) do
                local s = image_settings(path)
                obs.obs_source_update(slot.img, s)
                obs.obs_data_release(s)
            end
            self.path = path
        end
        self.tex_w = tex_w or measure(self)
    end)
    if not ok then
        log.warn("Click ripple could not be set up: %s", tostring(err))
        self:destroy()
        return false
    end
    return true
end

local function item_alive(host)
    local scene = obs.obs_sceneitem_get_scene(host.item)
    return scene ~= nil and obs.obs_scene_find_sceneitem_by_id(scene, host.id) ~= nil
end

-- The scene that will hold the overlay, the item to stack it above, and whether the capture is in a group
local function host_for(si)
    local scene = obs.obs_sceneitem_get_scene(si.item)
    if scene == nil then
        return nil
    end
    if obs.obs_scene_is_group(scene) then
        if si.group_item == nil then
            return nil
        end
        return obs.obs_sceneitem_get_scene(si.group_item), si.group_item, true
    end
    return scene, si.item, false
end

---
-- Make sure the overlay item sits directly above the capture item (re-created if it went missing).
---@param si table scene item controller
---@return boolean ready
function Ripple:ensure_host(si)
    if self.overlay == nil or si.item == nil or self.blocked then
        return false
    end
    local scene, anchor, grouped = host_for(si)
    if scene == nil then
        log.debug("Click ripple: the scene of the capture item is unknown")
        return false
    end

    -- Rotation and flips are not handled by the ripple math
    for _, it in ipairs(grouped and { si.item, si.group_item } or { si.item }) do
        local info = read_info(it)
        if info.rot ~= 0 or info.scale.x < 0 or info.scale.y < 0 then
            self.blocked = true
            log.warn("Click ripple is off for this capture: it is rotated or flipped, which the ripple cannot follow.")
            return false
        end
    end

    local name = scene_name(scene)
    local host = self.host
    if host ~= nil then
        if host.name == name and host.grouped == grouped and item_alive(host) then
            return true
        end
        self:detach_host()
    end

    local item = obs.obs_scene_add(scene, obs.obs_scene_get_source(self.overlay))
    if item == nil then
        log.warn("Click ripple: could not add the overlay to scene '%s'.", name)
        return false
    end
    obs.obs_sceneitem_addref(item)
    local info = read_info(item)
    info.pos.x, info.pos.y = 0, 0
    info.scale.x, info.scale.y = 1, 1
    info.rot = 0
    info.alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT)
    info.bounds_type = obs.OBS_BOUNDS_NONE
    set_info(item, info)
    obs.obs_sceneitem_set_locked(item, true)

    -- Directly above the capture item. On failure the overlay stays on top, which is fine.
    local order = nil
    local okp, errp = pcall(function()
        local idx = index_of(scene, anchor)
        if idx ~= nil then
            order = idx + 1
            obs.obs_sceneitem_set_order_position(item, order)
        end
    end)
    if not okp then
        log.debug("Click ripple: could not order the overlay (%s)", tostring(errp))
    end

    self.host = { item = item, id = obs.obs_sceneitem_get_id(item), name = name, grouped = grouped, order = order }
    log.debug("Click overlay added to scene '%s'%s", name, grouped and " (capture is in a group)" or "")
    return true
end

local function hide_slot(self, slot)
    if slot.item ~= nil then
        pcall(obs.obs_sceneitem_set_visible, slot.item, false)
    end
    self.pool:release(slot)
end

---
-- Remove the overlay item from the capture's scene (running ripples are dropped).
function Ripple:detach_host()
    self.blocked = false
    if self.pool ~= nil then
        self.pool:each_active(function(slot) hide_slot(self, slot) end)
    end
    local host = self.host
    if host == nil then
        return
    end
    self.host = nil
    -- If the scene already dropped the item (the user deleted it) there is nothing to remove
    local scene = nil
    pcall(function() scene = obs.obs_sceneitem_get_scene(host.item) end)
    if scene ~= nil then
        local ok, err = pcall(obs.obs_sceneitem_remove, host.item)
        if not ok then
            log.debug("Click overlay remove failed: %s", tostring(err))
        end
    end
    pcall(obs.obs_sceneitem_release, host.item)
    log.debug("Click overlay removed from scene '%s'", host.name)
end

---
-- Start a ripple at a camera-space point (call ensure_host first)
---@param cx number
---@param cy number
---@param now number
function Ripple:spawn(cx, cy, now)
    if self.pool == nil or self.host == nil then
        return
    end
    local slot = self.pool:acquire(now)
    slot.ax, slot.ay = cx, cy
    pcall(obs.obs_sceneitem_set_visible, slot.item, false) -- shown by the first update
end

-- Where a camera-space point is on the canvas: p, the view and content rects, and the group scale k
function Ripple:locate(si, ax, ay)
    local w = si.written
    if w == nil then
        return nil
    end
    local view = { x = w.l, y = w.t, w = w.w, h = w.h }
    local content = geometry.item_content_rect(read_info(si.item), view.w, view.h, self.B)
    local px, py = geometry.camera_to_canvas(ax, ay, view, content)
    local k = 1
    if self.host ~= nil and self.host.grouped and si.group_item ~= nil then
        local gsrc = obs.obs_sceneitem_get_source(si.group_item)
        local gw, gh = obs.obs_source_get_width(gsrc), obs.obs_source_get_height(gsrc)
        if gw > 0 and gh > 0 then
            local gc = geometry.item_content_rect(read_info(si.group_item), gw, gh, self.B)
            px, py = geometry.map_point(px, py, gw, gh, gc)
            k = gc.w / gw
        end
    end
    local inside = ax >= view.x and ax <= view.x + view.w and ay >= view.y and ay <= view.y + view.h
    return { x = px, y = py, k = k, view = view, content = content, inside = inside }
end

local function set_opacity(self, slot, op)
    if slot.filter == nil then
        return
    end
    local v = self.fade == "v1" and math.floor(op * 100 + 0.5) or op
    if slot.op == v then
        return
    end
    slot.op = v
    if self.fade == "v1" then
        obs.obs_data_set_int(slot.fdata, "opacity", v)
    else
        obs.obs_data_set_double(slot.fdata, "opacity", v)
    end
    obs.obs_source_update(slot.filter, slot.fdata)
end

---
-- Advance the running ripples. Call every tick: it re-reads the applied crop, so the ring follows the zoomed view.
---@param si table scene item controller
---@param now number
---@param cam_w number Width of the full camera picture
function Ripple:update(si, now, cam_w)
    if self.pool == nil or not self.pool:any_active() then
        return
    end
    if self.host == nil then
        self.pool:each_active(function(slot) hide_slot(self, slot) end)
        return
    end
    if self.tex_w <= 0 then
        self.tex_w = measure(self)
        if self.tex_w <= 0 then
            self.tex_w = 256
            log.warn("Click ripple: could not read the image size, assuming 256 pixels.")
        end
    end
    local rc = self.cfg
    self.pool:each_active(function(slot)
        local a = anim.sample(now - slot.t0, rc.duration, { opacity = rc.opacity })
        if a.done then
            hide_slot(self, slot)
            return
        end
        local loc = self:locate(si, slot.ax, slot.ay)
        if loc == nil then
            return
        end
        self.last = { ax = slot.ax, ay = slot.ay, p = loc }
        local zoom = rc.zoom_scale and cam_w / loc.view.w or 1
        local d = rc.size * loc.k * zoom * a.scale

        set_opacity(self, slot, a.opacity)
        local info = read_info(slot.item)
        info.pos.x, info.pos.y = loc.x, loc.y
        info.scale.x, info.scale.y = d / self.tex_w, d / self.tex_w
        info.alignment = 0 -- center
        info.rot = 0
        info.bounds_type = obs.OBS_BOUNDS_NONE
        set_info(slot.item, info)
        obs.obs_sceneitem_set_visible(slot.item, loc.inside)
    end)
end

---
-- Remove everything we created: the overlay item, the slots and the overlay scene.
function Ripple:destroy()
    self:detach_host()
    if self.pool ~= nil then
        for _, slot in ipairs(self.pool.slots) do
            slot.active = false
            if slot.filter ~= nil and slot.img ~= nil then
                pcall(obs.obs_source_filter_remove, slot.img, slot.filter)
            end
            if slot.filter ~= nil then pcall(obs.obs_source_release, slot.filter) end
            if slot.fdata ~= nil then pcall(obs.obs_data_release, slot.fdata) end
            if slot.item ~= nil then
                pcall(obs.obs_sceneitem_remove, slot.item)
                pcall(obs.obs_sceneitem_release, slot.item)
            end
            if slot.img ~= nil then pcall(obs.obs_source_release, slot.img) end
            slot.filter, slot.fdata, slot.item, slot.img = nil, nil, nil, nil
        end
    end
    if self.overlay ~= nil then
        pcall(obs.obs_scene_release, self.overlay)
    end
    self.overlay, self.pool, self.path, self.last = nil, nil, nil, nil
end

---
---@param si table|nil scene item controller (for the draw transform cross-check)
---@return table lines for Diagnose
function Ripple:describe(si)
    if self.overlay == nil then
        return { "ripple: off" }
    end
    local lines = { "ripple: image " .. tostring(self.path) .. ", " .. tostring(self.tex_w) .. " px" }
    lines[#lines + 1] = "opacity filter: " .. tostring(self.fade) ..
        (self.fade == "v2" and " (color_filter_v2)" or (self.fade == "v1" and " (color_filter)" or ""))
    local h = self.host
    if h == nil then
        lines[#lines + 1] = "overlay item: not in a scene right now (added on the next click)"
    else
        lines[#lines + 1] = string.format("overlay item: id %s in scene '%s' at order index %s, capture in a group: %s",
            tostring(h.id), tostring(h.name), tostring(h.order), tostring(h.grouped))
    end
    if self.blocked then
        lines[#lines + 1] = "ripple is off for this capture (rotated or flipped)"
    end
    local l = self.last
    if l ~= nil then
        local p = l.p
        lines[#lines + 1] = string.format("last click: camera (%.1f,%.1f) -> canvas (%.1f,%.1f), group scale %.3f",
            l.ax, l.ay, p.x, p.y, p.k)
        lines[#lines + 1] = string.format("  view rect: x=%.1f y=%.1f w=%.1f h=%.1f; content rect: x=%.1f y=%.1f w=%.1f h=%.1f",
            p.view.x, p.view.y, p.view.w, p.view.h, p.content.x, p.content.y, p.content.w, p.content.h)
        if si ~= nil and si.item ~= nil then
            local ok, text = pcall(function()
                local m = obs.matrix4()
                obs.obs_sceneitem_get_draw_transform(si.item, m)
                return string.format("draw transform origin (%.1f,%.1f) vs content rect origin (%.1f,%.1f)",
                    m.t.x, m.t.y, p.content.x, p.content.y)
            end)
            lines[#lines + 1] = "  cross-check: " .. (ok and text or ("unavailable (" .. tostring(text) .. ")"))
        end
    end
    return lines
end

return M
end

package.preload["cinezoom.effects.ripple_anim"] = function(...)
-- Ripple animation curve (pure): the ring grows with an ease-out and fades over time.
local M = {}

M.START_SCALE = 0.25

local function smoothstep(a, b, x)
    local u = math.max(0, math.min(1, (x - a) / (b - a)))
    return u * u * (3 - 2 * u)
end

---
-- State of a ripple at `age` seconds
---@param age number Seconds since the click
---@param duration number Total seconds
---@param cfg table|nil {opacity = peak opacity 0..1 (default 1)}
---@return table {scale, opacity, done}
function M.sample(age, duration, cfg)
    local max_op = cfg and cfg.opacity or 1
    local u = math.max(0, math.min(1, age / math.max(duration, 1e-3)))
    local s0 = M.START_SCALE
    return {
        scale = s0 + (1 - s0) * (1 - (1 - u) ^ 3),
        opacity = max_op * (1 - smoothstep(0.3, 1, u)),
        done = age >= duration,
    }
end

return M
end

package.preload["cinezoom.effects.sound"] = function(...)
-- Click sound: a small pool of private ffmpeg_sources, each attached to a free output channel so the
-- click is part of the audio mix (recording and stream). Private sources are never saved and
-- channels from 7 up are not saved either, so nothing ends up in the user's scene collection.
local obs = obslua
local log = require("cinezoom.log")
local opt = require("cinezoom.obs.opt")

local M = {}

M.VOICES = 2            -- a new click restarts the idle source, not the one still finishing
local FIRST_CHANNEL = 63
local LAST_CHANNEL = 8
local ALL_TRACKS = 0x3F

local Sound = {}
Sound.__index = Sound

---
---@return table sound controller (creates nothing until configure)
function M.new()
    return setmetatable({ voices = {}, next_voice = 1, path = nil }, Sound)
end

local function file_settings(path)
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "local_file", path)
    obs.obs_data_set_bool(s, "is_local_file", true)
    obs.obs_data_set_bool(s, "looping", false)
    obs.obs_data_set_bool(s, "restart_on_activate", false)
    obs.obs_data_set_bool(s, "close_when_inactive", false)
    obs.obs_data_set_bool(s, "clear_on_media_end", true)
    obs.obs_data_set_bool(s, "hw_decode", false)
    return s
end

-- Highest free output channel (63 down to 8)
local function free_channel()
    for ch = FIRST_CHANNEL, LAST_CHANNEL, -1 do
        local cur = obs.obs_get_output_source(ch)
        if cur == nil then
            return ch
        end
        obs.obs_source_release(cur)
    end
    return nil
end

local function apply_levels(voice, cfg)
    local v = math.max(0, math.min(100, cfg.volume)) / 100
    obs.obs_source_set_volume(voice.src, v * v)
    local mon = opt(cfg.monitor and "OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT" or "OBS_MONITORING_TYPE_NONE")
    if mon ~= nil then
        obs.obs_source_set_monitoring_type(voice.src, mon)
    end
end

local function create_voice(self, index, path, cfg)
    local s = file_settings(path)
    local src = obs.obs_source_create_private("ffmpeg_source", "OBSCineZoom click " .. index, s)
    obs.obs_data_release(s)
    if src == nil then
        return nil, "could not create the ffmpeg_source"
    end
    local voice = { src = src, ch = nil }
    self.voices[#self.voices + 1] = voice
    obs.obs_source_set_audio_mixers(src, ALL_TRACKS)
    apply_levels(voice, cfg)
    -- ffmpeg_source starts playing when it is created or activated, which would click at load:
    -- stay muted until the first real play()
    obs.obs_source_set_muted(src, true)
    local ch = free_channel()
    if ch == nil then
        return nil, "no free output channel"
    end
    obs.obs_set_output_source(ch, src)
    voice.ch = ch
    return voice
end

---
-- Create the voices on first use, then apply a changed file, volume or monitoring.
---@param cfg table {volume, monitor}
---@param path string Audio file to play
---@return boolean ok
function Sound:configure(cfg, path)
    local ok, err = pcall(function()
        if #self.voices == 0 then
            for i = 1, M.VOICES do
                local voice, why = create_voice(self, i, path, cfg)
                if voice == nil then
                    error(why, 0)
                end
            end
            self.path = path
            log.debug("Click sound ready on channels %d, %d", self.voices[1].ch, self.voices[2] and self.voices[2].ch or -1)
            return
        end
        if path ~= self.path then
            for _, voice in ipairs(self.voices) do
                local s = file_settings(path)
                obs.obs_source_update(voice.src, s)
                obs.obs_data_release(s)
            end
            self.path = path
        end
        for _, voice in ipairs(self.voices) do
            apply_levels(voice, cfg)
        end
    end)
    if not ok then
        log.warn("Click sound could not be set up: %s", tostring(err))
        self:destroy()
        return false
    end
    return true
end

---
-- Play one click (round robin over the voices)
---@return boolean played
function Sound:play()
    local voice = self.voices[self.next_voice]
    if voice == nil then
        return false
    end
    self.next_voice = self.next_voice % #self.voices + 1
    obs.obs_source_set_muted(voice.src, false)
    local restart = opt("obs_source_media_restart")
    if restart ~= nil then
        local ok, err = pcall(restart, voice.src)
        if not ok then
            log.debug("media_restart failed: %s", tostring(err))
            restart = nil
        end
    end
    if restart == nil then
        -- No restart call: updating the settings makes the source reopen the file
        local s = file_settings(self.path)
        obs.obs_source_update(voice.src, s)
        obs.obs_data_release(s)
    end
    return true
end

---
-- OBS may clear output channels when the scene collection changes: put our sources back
function Sound:reattach()
    for _, voice in ipairs(self.voices) do
        if voice.ch ~= nil then
            local ok, err = pcall(function()
                local cur = obs.obs_get_output_source(voice.ch)
                -- compare names: wrappers of the same source are not always the same object
                local ours = false
                if cur ~= nil then
                    ours = obs.obs_source_get_name(cur) == obs.obs_source_get_name(voice.src)
                    obs.obs_source_release(cur)
                end
                if not ours then
                    obs.obs_set_output_source(voice.ch, voice.src)
                    log.debug("Click sound re-attached to channel %d", voice.ch)
                end
            end)
            if not ok then
                log.debug("Click sound re-attach failed: %s", tostring(err))
            end
        end
    end
end

function Sound:destroy()
    for _, voice in ipairs(self.voices) do
        pcall(function()
            if voice.ch ~= nil then
                local cur = obs.obs_get_output_source(voice.ch)
                if cur ~= nil then
                    local ours = obs.obs_source_get_name(cur) == obs.obs_source_get_name(voice.src)
                    obs.obs_source_release(cur)
                    if ours then
                        obs.obs_set_output_source(voice.ch, nil)
                    end
                end
            end
        end)
        pcall(obs.obs_source_release, voice.src)
    end
    self.voices = {}
    self.next_voice = 1
    self.path = nil
end

---
---@return table lines for Diagnose
function Sound:describe()
    if #self.voices == 0 then
        return { "sound: off" }
    end
    local lines = { "sound: file " .. tostring(self.path) }
    for i, voice in ipairs(self.voices) do
        local ok, text = pcall(function()
            return string.format("voice %d: channel %s, media state %s, volume %.3f, muted %s, monitoring %s", i,
                tostring(voice.ch), tostring(obs.obs_source_media_get_state(voice.src)),
                obs.obs_source_get_volume(voice.src), tostring(obs.obs_source_muted(voice.src)),
                tostring(obs.obs_source_get_monitoring_type(voice.src)))
        end)
        lines[#lines + 1] = ok and text or string.format("voice %d: channel %s (state unavailable: %s)", i,
            tostring(voice.ch), tostring(text))
    end
    return lines
end

return M
end

package.preload["cinezoom.geometry"] = function(...)
-- Pure coordinate math, no OBS or FFI. The pipeline for one mouse sample is:
--   global mouse units -> display-local -> source pixels -> camera space -> crop rect
-- "Camera space" is the picture left after any crop the user already applies to the source.
local M = {}

---
-- Clamps a value between lo and hi
---@return number
function M.clamp(v, lo, hi)
    if hi < lo then
        return lo
    end
    return math.max(lo, math.min(hi, v))
end

---
-- 1. Make a global mouse position relative to the top-left of display d
---@param x number
---@param y number
---@param d table Display {x, y, w, h} in mouse units
---@return number x, number y
function M.to_display_local(x, y, d)
    return x - d.x, y - d.y
end

---
-- 2. Convert display-local mouse units into pixels of the source.
-- src_w/src_h must be the source size BEFORE any filters. If the size is not known yet
-- (0) we fall back to the display's pixel size, so Retina still gets its 2x.
-- A display with explicit scale_x/scale_y (manual override) uses those instead.
---@return number x, number y
function M.to_source_px(x, y, d, src_w, src_h)
    local sx, sy = d.scale_x, d.scale_y
    if not sx or sx <= 0 then
        if src_w and src_w > 0 then
            sx = src_w / d.w
        elseif d.px_w and d.px_w > 0 then
            sx = d.px_w / d.w
        else
            sx = 1
        end
    end
    if not sy or sy <= 0 then
        if src_h and src_h > 0 then
            sy = src_h / d.h
        elseif d.px_h and d.px_h > 0 then
            sy = d.px_h / d.h
        else
            sy = 1
        end
    end
    return x * sx, y * sy
end

---
-- 3. Offset by the user's own crop. This MUST happen after scaling because the crop
-- is measured in source pixels, not mouse units.
---@param crop table|nil {x, y}
---@return number x, number y
function M.to_camera_space(x, y, crop)
    if not crop then
        return x, y
    end
    return x - crop.x, y - crop.y
end

---
-- 4. The rectangle the camera shows: centered on (cx, cy), 1/z of the full size,
-- kept inside the camera area. Values stay fractional; only the crop write floors them.
---@return table rect {x, y, w, h}
function M.view_rect(cx, cy, z, cam_w, cam_h)
    if not z or z < 1 then
        z = 1
    end
    local w = cam_w / z
    local h = cam_h / z
    return {
        x = M.clamp(cx - w * 0.5, 0, cam_w - w),
        y = M.clamp(cy - h * 0.5, 0, cam_h - h),
        w = w,
        h = h,
    }
end

---
-- 5. Map a camera-space point to canvas coordinates (for later overlays).
-- item is where the camera output sits on the canvas {x, y, w, h}.
---@return number x, number y
function M.camera_to_canvas(x, y, view, item)
    return item.x + (x - view.x) / view.w * item.w,
        item.y + (y - view.y) / view.h * item.h
end

---
-- Offset of the alignment anchor inside a w x h box. Flags: LEFT=1, RIGHT=2, TOP=4, BOTTOM=8,
-- 0 (or both of a pair) is the center.
---@return number x, number y
function M.align_offset(align, w, h)
    align = align or 0
    local x, y = w / 2, h / 2
    if align % 2 >= 1 then
        x = 0
    elseif align % 4 >= 2 then
        x = w
    end
    if align % 8 >= 4 then
        y = 0
    elseif align % 16 >= 8 then
        y = h
    end
    return x, y
end

---
-- Where the content of a scene item is drawn, in the coordinates of the scene that holds it.
-- info is an obs_transform_info (as a table), src_w/src_h the size of the source after filters,
-- B the bounds constants {NONE, STRETCH, SCALE_INNER, SCALE_OUTER, SCALE_TO_WIDTH, SCALE_TO_HEIGHT, MAX_ONLY}.
-- Rotation and flips are ignored (callers warn about them).
---@return table rect {x, y, w, h}
function M.item_content_rect(info, src_w, src_h, B)
    if info.bounds_type == B.NONE then
        local w, h = src_w * info.scale.x, src_h * info.scale.y
        local ox, oy = M.align_offset(info.alignment, w, h)
        return { x = info.pos.x - ox, y = info.pos.y - oy, w = w, h = h }
    end

    local bx, by = info.bounds.x, info.bounds.y
    local fx, fy = bx / src_w, by / src_h
    local bt = info.bounds_type
    if bt == B.STRETCH then
        -- both factors as they are
    elseif bt == B.SCALE_OUTER then
        fx = math.max(fx, fy); fy = fx
    elseif bt == B.SCALE_TO_WIDTH then
        fy = fx
    elseif bt == B.SCALE_TO_HEIGHT then
        fx = fy
    elseif bt == B.MAX_ONLY then
        fx = math.min(1, math.min(fx, fy)); fy = fx
    else -- SCALE_INNER and anything unknown
        fx = math.min(fx, fy); fy = fx
    end
    local w, h = src_w * fx, src_h * fy
    local ox, oy = M.align_offset(info.alignment, bx, by)
    local ix, iy = M.align_offset(info.bounds_alignment, bx - w, by - h)
    return { x = info.pos.x - ox + ix, y = info.pos.y - oy + iy, w = w, h = h }
end

---
-- Map a point of a from_w x from_h picture to where that picture is drawn (rect)
---@return number x, number y
function M.map_point(x, y, from_w, from_h, rect)
    return rect.x + x / from_w * rect.w, rect.y + y / from_h * rect.h
end

---
-- Parse a display list name such as "U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
---@param s string
---@return table|nil rect {x, y, w, h}, nil unless size AND position were found
function M.parse_display_name(s)
    if type(s) ~= "string" then
        return nil
    end
    local w, h = s:match("(%d+)x(%d+)")
    local x, y = s:match("@%s*(-?%d+)%s*,%s*(-?%d+)")
    if not (w and h and x and y) then
        return nil
    end
    w, h = tonumber(w), tonumber(h)
    if w == 0 or h == 0 then
        return nil
    end
    return { x = tonumber(x), y = tonumber(y), w = w, h = h }
end

---
-- Cocoa rects have a bottom-left origin relative to the main display;
-- mouse coordinates use a top-left origin.
---@param r table {x, y, w, h} in Cocoa space
---@param main_h number Height of the main display
---@return table rect in top-left space
function M.cocoa_rect_to_cg(r, main_h)
    return { x = r.x, y = main_h - (r.y + r.h), w = r.w, h = r.h }
end

---
-- Case-insensitive UUID comparison (empty never matches)
---@return boolean
function M.uuid_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then
        return false
    end
    return a:upper() == b:upper()
end

return M
end

package.preload["cinezoom.log"] = function(...)
-- Logging for OBSCineZoom.
-- info/warn/error ALWAYS print (so users see problems without enabling anything),
-- debug only prints when the "Enable debug logging" checkbox is on.
local M = {}

-- Values of OBS_LOG_ERROR / OBS_LOG_WARNING / OBS_LOG_INFO (used when the constants are missing)
local LEVELS = { error = 100, warn = 200, info = 300 }
local CONST = { error = "OBS_LOG_ERROR", warn = "OBS_LOG_WARNING", info = "OBS_LOG_INFO" }

M.debug_enabled = false
M.sink = nil -- optional function(level, msg) that replaces OBS output (used by tests)

local function emit(level, msg)
    if M.sink then
        return M.sink(level, msg)
    end
    local obs = rawget(_G, "obslua")
    if obs ~= nil and obs.script_log ~= nil then
        obs.script_log(obs[CONST[level]] or LEVELS[level], msg)
    end
end

local function format(fmt, ...)
    if select("#", ...) == 0 then
        return tostring(fmt)
    end
    local ok, s = pcall(string.format, fmt, ...)
    return ok and s or tostring(fmt)
end

function M.info(fmt, ...) emit("info", format(fmt, ...)) end
function M.warn(fmt, ...) emit("warn", "WARNING: " .. format(fmt, ...)) end
function M.error(fmt, ...) emit("error", "ERROR: " .. format(fmt, ...)) end

function M.debug(fmt, ...)
    if M.debug_enabled then
        emit("info", "[debug] " .. format(fmt, ...))
    end
end

---
-- Format a lua table into a readable string (keys sorted so output is stable)
---@param tbl table
---@param indent number|nil
---@return string
function M.dump(tbl, indent)
    indent = indent or 0
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local pad = string.rep("  ", indent + 1)
    local str = "{\n"
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            str = str .. pad .. tostring(k) .. " = " .. M.dump(v, indent + 1) .. ",\n"
        else
            str = str .. pad .. tostring(k) .. " = " .. tostring(v) .. ",\n"
        end
    end
    return str .. string.rep("  ", indent) .. "}"
end

return M
end

package.preload["cinezoom.main"] = function(...)
-- OBSCineZoom entry point. install(env) defines the script_* callbacks OBS looks for.
-- All state lives in locals inside install(), so nothing else leaks into the global table.
local obs = obslua

local log = require("cinezoom.log")
local version = require("cinezoom.version")
local geometry = require("cinezoom.geometry")
local camera = require("cinezoom.camera")
local deadzone = require("cinezoom.deadzone")
local autozoom = require("cinezoom.autozoom")
local platform = require("cinezoom.platform")
local sources = require("cinezoom.obs.sources")
local sceneitem = require("cinezoom.obs.sceneitem")
local opt = require("cinezoom.obs.opt")
local fx_mod = require("cinezoom.effects")
local settings_mod = require("cinezoom.settings")
local remote_mod = require("cinezoom.remote")
local diagnose = require("cinezoom.diagnose")

local M = {}

M.VERSION = "0.1.0"

local HOTKEY_KEYS = {
    zoom = "cinezoom.hotkey.zoom",
    follow = "cinezoom.hotkey.follow",
    auto = "cinezoom.hotkey.auto",
}

local HELP = [[
----------------------------------------------------
OBSCineZoom v%s
Based on obs-zoom-to-mouse by BlankSourceCode (MIT)
----------------------------------------------------
Zoom the selected display-capture source to follow the mouse.

Hotkeys (set them in OBS Settings > Hotkeys):
  OBSCineZoom: Toggle zoom to mouse / Toggle follow mouse / Toggle auto-zoom

Source: the display capture in the current scene. "Allow any zoom source" needs a manual position.
Zoom Factor: how far to zoom in.
Motion: how snappy the camera is (a critically damped spring, so no overshoot).
Follow: Auto follow starts tracking when you zoom in; the Deadzone is the area around the
  view center where the mouse can move without the view following.
Auto-zoom: zoom in on clicks, zoom out after a pause. Typing and fast mouse movement are optional.
Click effects (off by default): a click sound and a click ripple. "Test click effects" tries them.
Manual source position: override the display position/size (mouse units) when it cannot be found.
Diagnose: log everything needed for a bug report, then probe the mouse for 5 seconds.
]]

---
-- Install the script_* callbacks into env (the script's global table)
---@param env table
function M.install(env)
    -- Looked up when used so tests can pretend to be on another platform
    local function OS() return platform.os_name() end
    local obs_version = obs.obs_get_version_string()

    local cfg = nil              -- settings table (see settings.lua)
    local backend = nil          -- mouse backend
    local si = sceneitem.new()
    local cam = camera.new(1920, 1080)
    local az = autozoom.new()
    local remote = remote_mod.new()
    remote.running = false
    local fx = fx_mod.new()      -- click effects (nothing is created until one is switched on)
    local fx_proj = nil          -- {mx, my, inside} of the current tick, nil if there was no projection
    local fx_errors = 0          -- consecutive fx_tick failures

    local display, display_note = nil, "not resolved yet"
    local clock = 0
    local zoomed = false         -- the camera is zooming/zoomed in
    local following = false
    local target = { x = 960, y = 540 } -- camera center target (camera space)
    local last_input = nil       -- latest raw input sample
    local prev_counts = { clicks = nil, keys = nil }
    local remote_clock = 0
    local input_error_logged = false

    local hotkeys = { zoom = nil, follow = nil, auto = nil }
    local obs_loaded = false
    local script_loaded = false

    ----------------------------------------------------------------------
    -- helpers
    ----------------------------------------------------------------------
    local function stiffness_changed()
        camera.set_stiffness(cam, settings_mod.stiffness(cfg))
    end

    -- Forget any zoom: used when the source, scene or size changes
    local function reset_zoom()
        zoomed, following = false, false
        autozoom.reset(az)
        camera.set_bounds(cam, math.max(si.cam_w, 1), math.max(si.cam_h, 1))
        target.x, target.y = cam.w / 2, cam.h / 2
    end

    local function resolve_display()
        if si.source == nil and not (cfg.override.enabled and cfg.override.w > 0) then
            display, display_note = nil, "no zoom source"
            return
        end
        display, display_note = sources.resolve_display(si.source, {
            os = OS(), backend = backend, override = cfg.override,
        })
        if display then
            log.debug("Display resolved via %s: %sx%s @ %s,%s", tostring(display.method),
                display.w, display.h, display.x, display.y)
        end
    end

    -- Find the scene item for the selected source and prepare it
    local function attach()
        fx:detach_host() -- the overlay item must not outlive the scene item it sits above
        local name = cfg.source
        if name == "" or name == sources.NONE then
            -- No zoom source: restore everything so users can edit crops, then re-select
            si:release()
            display, display_note = nil, "no zoom source"
            reset_zoom()
            return
        end

        local ok = si:attach(name, function(src)
            return sources.is_capture(obs.obs_source_get_id(src), OS())
        end)
        if ok and not si.is_capture and not cfg.override.enabled then
            log.error("Selected Zoom Source is not a display capture source. " ..
                "You MUST enable 'Set manual source position' and set the correct size and position.")
        end
        resolve_display()
        reset_zoom()
    end

    -- Camera-space position of a global mouse position (nil if there is no display yet)
    local function project(gx, gy)
        if gx == nil or display == nil or not si.ready then
            return nil
        end
        local lx, ly = geometry.to_display_local(gx, gy, display)
        local px, py = geometry.to_source_px(lx, ly, display, si.base_w, si.base_h)
        local cx, cy = geometry.to_camera_space(px, py, si.user_crop)
        return px, py, cx, cy
    end

    local function read_input()
        local gx, gy
        if remote.mouse then
            gx, gy = remote.mouse.x, remote.mouse.y
        else
            gx, gy = backend.mouse()
        end
        local left, clicks = backend.buttons()
        local keys = backend.key_activity()
        return gx, gy, left, clicks, keys
    end

    local function sample()
        local s = last_input
        if not s then
            local ok, gx, gy, left, clicks, keys = pcall(read_input)
            s = ok and { gx = gx, gy = gy, left = left, clicks = clicks, keys = keys } or {}
        end
        local sx, sy, cx, cy = project(s.gx, s.gy)
        return { gx = s.gx, gy = s.gy, sx = sx, sy = sy, cx = cx, cy = cy,
            left = s.left, clicks = s.clicks, keys = s.keys }
    end

    local function diagnose_context()
        return {
            version = M.VERSION, obs_version = obs_version, backend = backend, si = si,
            display = display, display_note = display_note, sample = sample, fx = fx,
            state = { zoomed = zoomed, following = following, auto = az.enabled },
        }
    end

    -- Difference of a monotonically increasing counter between ticks
    local function delta(name, value)
        local d = 0
        if value ~= nil and prev_counts[name] ~= nil and value > prev_counts[name] then
            d = value - prev_counts[name]
        end
        prev_counts[name] = value
        return d
    end

    ----------------------------------------------------------------------
    -- hotkeys
    ----------------------------------------------------------------------
    local function on_toggle_zoom(pressed)
        if not pressed then return end
        if not si.ready then
            log.warn("Cannot zoom yet: no zoom source is ready. Select a Zoom Source and run Diagnose if this persists.")
            return
        end
        if zoomed then
            log.debug("Zooming out")
            autozoom.set_manual(az, clock, false)
        else
            log.debug("Zooming in")
            local focus = nil
            if last_input then
                local _, _, cx, cy = project(last_input.gx, last_input.gy)
                if cx then focus = { x = cx, y = cy } end
            end
            autozoom.set_manual(az, clock, true, focus)
        end
    end

    local function on_toggle_follow(pressed)
        if pressed then
            following = not following
            log.debug("Tracking mouse is %s", following and "on" or "off")
        end
    end

    local function on_toggle_auto(pressed)
        if pressed then
            autozoom.set_enabled(az, not az.enabled)
            log.info("Auto-zoom is %s", az.enabled and "on" or "off")
        end
    end

    ----------------------------------------------------------------------
    -- the tick loop
    ----------------------------------------------------------------------
    local function zoom_tick(seconds)
        fx_proj = nil
        if not script_loaded or backend == nil then
            return
        end
        clock = clock + seconds
        diagnose.tick(seconds)

        if remote.server and clock - remote_clock >= (cfg.socket.poll / 1000) then
            remote_clock = clock
            remote_mod.poll(remote)
        end

        local ok, gx, gy, left, clicks, keys = pcall(read_input)
        if not ok then
            if not input_error_logged then
                input_error_logged = true
                log.error("Mouse backend failed (%s). Mouse following is disabled.", tostring(gx))
            end
            backend = require("cinezoom.platform.null").new(tostring(gx))
            return
        end
        last_input = { gx = gx, gy = gy, left = left, clicks = clicks, keys = keys }

        if si.item == nil then
            return
        end

        -- A source can report size 0 until its first frame, and the size can change later
        if si:poll_size() then
            resolve_display()
            reset_zoom()
        end
        if not si.ready then
            return
        end

        local _, _, mx, my = project(gx, gy)
        local inside = mx ~= nil and mx >= 0 and my >= 0 and mx < si.cam_w and my < si.cam_h
        fx_proj = { mx = mx, my = my, inside = inside }

        local res = autozoom.update(az, clock, {
            x = mx, y = my, inside = inside,
            clicks = delta("clicks", clicks), left_down = left, keys = delta("keys", keys),
            cam_w = si.cam_w,
        })
        if res.zoom ~= zoomed then
            zoomed = res.zoom
            following = zoomed and cfg.follow
            log.debug("Zoom %s", zoomed and "in" or "out")
        end
        if res.focus then
            target.x, target.y = res.focus.x, res.focus.y
        end

        if zoomed then
            local vw, vh = si.cam_w / cfg.zoom, si.cam_h / cfg.zoom
            if following and mx ~= nil and (inside or cfg.follow_outside) then
                target.x, target.y = deadzone.apply(target.x, target.y, mx, my, vw, vh, cfg.deadzone)
            end
            target.x = geometry.clamp(target.x, vw / 2, si.cam_w - vw / 2)
            target.y = geometry.clamp(target.y, vh / 2, si.cam_h - vh / 2)
        end

        camera.set_target(cam, target.x, target.y, zoomed and cfg.zoom or 1)
        camera.step(cam, seconds)
        si:set_crop(camera.rect(cam))
    end

    -- Click effects. Runs after the zoom tick, so "zoomed" already includes an auto zoom-in
    -- caused by this very click. The click count has its own counter key: autozoom's is untouched.
    local function fx_tick(seconds)
        if not fx:active() then
            prev_counts.fx_clicks = nil -- do not replay clicks made while the effects were off
            return
        end
        if last_input == nil then
            return
        end
        local n = delta("fx_clicks", last_input.clicks)
        local proj = fx_proj
        local inside = proj ~= nil and proj.inside
        if n > 0 and cfg.fx.only_inside and not inside then
            n = 0
        end
        if n > 0 and cfg.fx.only_zoomed and not zoomed then
            n = 0
        end
        local cam_pt = proj ~= nil and proj.mx ~= nil and { x = proj.mx, y = proj.my } or nil
        fx:on_click(n, inside, cam_pt, si, clock)
        fx:tick(si, clock)
    end

    -- An error in the effects must never stop the zoom: three in a row turn them off
    local function run_fx(seconds)
        local ok, err = pcall(fx_tick, seconds)
        if ok then
            fx_errors = 0
            return
        end
        fx_errors = fx_errors + 1
        if fx_errors >= 3 then
            fx_errors = 0
            log.error("Click effects failed three times in a row (%s). They are turned off until you change a setting.",
                tostring(err))
            pcall(fx.disable, fx)
        else
            log.warn("Click effects error: %s", tostring(err))
        end
    end

    local function tick(seconds)
        zoom_tick(seconds)
        if script_loaded and backend ~= nil then
            run_fx(seconds)
        end
    end

    ----------------------------------------------------------------------
    -- OBS events
    ----------------------------------------------------------------------
    local function on_transition_start()
        log.debug("Transition started")
        fx:detach_host()
        -- Remove the crop as the transition starts to avoid showing the old crop for a moment
        si:release()
        reset_zoom()
    end

    -- These constants are missing in some OBS versions
    local EVENT_COLLECTION_CHANGING = opt("OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING")
    local EVENT_COLLECTION_CHANGED = opt("OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED")
    local EVENT_EXIT = opt("OBS_FRONTEND_EVENT_EXIT")

    local function on_frontend_event(event)
        if EVENT_COLLECTION_CHANGING ~= nil and event == EVENT_COLLECTION_CHANGING
            or EVENT_EXIT ~= nil and event == EVENT_EXIT then
            -- Nothing of ours may be left in scenes that are about to go away
            fx:on_collection_changing()
        elseif EVENT_COLLECTION_CHANGED ~= nil and event == EVENT_COLLECTION_CHANGED then
            pcall(fx.on_collection_changed, fx)
        elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
            log.debug("OBS Scene changed")
            -- Scene change can happen before OBS has completely loaded
            if obs_loaded then
                attach()
            end
        elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
            log.debug("OBS Loaded")
            obs_loaded = true
            attach()
        elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
            log.debug("OBS Shutting down")
            -- Fail-safe for unloading the script during shutdown
            if script_loaded then
                env.script_unload()
            end
        end
    end

    ----------------------------------------------------------------------
    -- script_* callbacks
    ----------------------------------------------------------------------
    function env.script_description()
        return "Zoom the selected display-capture source to follow the mouse (OBSCineZoom " .. M.VERSION .. ")"
    end

    function env.script_defaults(settings)
        settings_mod.defaults(settings)
    end

    function env.script_properties()
        return settings_mod.properties({
            os = OS(),
            cfg = function() return cfg end,
            on_refresh = function()
                resolve_display()
            end,
            on_diagnose = function()
                diagnose.run(diagnose_context())
            end,
            on_help = function()
                log.info(string.format(HELP, M.VERSION))
            end,
            on_fx_test = function()
                local s = sample()
                local ok, msg = pcall(fx.test_click, fx, s.cx ~= nil and { x = s.cx, y = s.cy } or nil, si, clock)
                log.info("%s", ok and msg or ("Click effects test failed: " .. tostring(msg)))
            end,
        })
    end

    function env.script_load(settings)
        cfg = settings_mod.read(settings)
        log.debug_enabled = cfg.debug
        backend = platform.get()
        az = autozoom.new(cfg.auto)
        stiffness_changed()

        -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
        local current_scene = obs.obs_frontend_get_current_scene()
        obs_loaded = current_scene ~= nil -- Current scene is nil on first OBS load
        if current_scene ~= nil then
            obs.obs_source_release(current_scene)
        end

        -- Register hotkeys and restore their bindings
        hotkeys.zoom = obs.obs_hotkey_register_frontend("cinezoom.toggle_zoom", "OBSCineZoom: Toggle zoom to mouse", on_toggle_zoom)
        hotkeys.follow = obs.obs_hotkey_register_frontend("cinezoom.toggle_follow", "OBSCineZoom: Toggle follow mouse during zoom", on_toggle_follow)
        hotkeys.auto = obs.obs_hotkey_register_frontend("cinezoom.toggle_auto", "OBSCineZoom: Toggle auto-zoom", on_toggle_auto)
        for name, id in pairs(hotkeys) do
            local array = obs.obs_data_get_array(settings, HOTKEY_KEYS[name])
            obs.obs_hotkey_load(id, array)
            obs.obs_data_array_release(array)
        end

        obs.obs_frontend_add_event_callback(on_frontend_event)

        -- Add the transition_start handler to each transition (the global source_transition_start event never fires)
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for _, s in pairs(transitions) do
                log.debug("Adding transition_start listener to %s", obs.obs_source_get_name(s))
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_connect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        if not backend.ok then
            log.warn("Mouse backend '%s' is not working: %s. Mouse following will not work. Run Diagnose for details.",
                backend.name, tostring(backend.reason))
        elseif backend.reason then
            log.warn("%s", backend.reason)
        end
        if cfg.debug then
            log.debug("Settings: %s", log.dump(cfg))
        end

        cfg.source = "" -- script_update sets it, which triggers the first attach
        script_loaded = true
    end

    function env.script_update(settings)
        local old = cfg
        cfg = settings_mod.read(settings)
        log.debug_enabled = cfg.debug
        stiffness_changed()
        autozoom.configure(az, cfg.auto)

        if cfg.source ~= old.source and obs_loaded then
            attach()
        elseif settings_mod.override_changed(old.override, cfg.override) and obs_loaded then
            resolve_display()
        end

        local okfx, errfx = pcall(fx.configure, fx, cfg.fx)
        if not okfx then
            log.error("Click effects could not be set up: %s", tostring(errfx))
            pcall(fx.destroy, fx)
        end

        local sock, osock = cfg.socket, old.socket
        if sock.enabled ~= remote.running then
            if sock.enabled then
                remote.running = remote_mod.start(remote, sock.port)
            else
                remote_mod.stop(remote)
                remote.running = false
            end
        elseif sock.enabled and (sock.port ~= osock.port or sock.poll ~= osock.poll) then
            remote_mod.stop(remote)
            remote.running = remote_mod.start(remote, sock.port)
        end
    end

    function env.script_tick(seconds)
        local ok, err = pcall(tick, seconds)
        if not ok then
            log.error("Tick failed: %s", tostring(err))
        end
    end

    function env.script_save(settings)
        for name, id in pairs(hotkeys) do
            if id ~= nil then
                local array = obs.obs_hotkey_save(id)
                obs.obs_data_set_array(settings, HOTKEY_KEYS[name], array)
                obs.obs_data_array_release(array)
            end
        end
    end

    function env.script_unload()
        script_loaded = false
        diagnose.cancel()

        -- 29.1.2 and below seems to crash if you do this, so we skip it as the script is closing anyway
        if version.at_least(obs_version, 29, 1, 3) then
            local function step(what, fn)
                local ok, err = pcall(fn)
                if not ok then
                    log.warn("Unload step '%s' failed: %s", what, tostring(err))
                end
            end

            step("transitions", function()
                local transitions = obs.obs_frontend_get_transitions()
                if transitions ~= nil then
                    for _, s in pairs(transitions) do
                        local handler = obs.obs_source_get_signal_handler(s)
                        obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
                    end
                    obs.source_list_release(transitions)
                end
            end)
            step("hotkeys", function()
                for name, id in pairs(hotkeys) do
                    if id ~= nil then
                        obs.obs_hotkey_unregister(id) -- takes the hotkey id, not the callback
                        hotkeys[name] = nil
                    end
                end
            end)
            step("frontend callback", function() obs.obs_frontend_remove_event_callback(on_frontend_event) end)
            step("click effects", function() fx:destroy() end)
            step("scene item", function() si:release() end)
        end

        if backend ~= nil then
            pcall(backend.close)
            backend = nil
        end
        if remote.server ~= nil then
            remote_mod.stop(remote)
            remote.running = false
        end
    end
end

return M
end

package.preload["cinezoom.obs.opt"] = function(...)
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
end

package.preload["cinezoom.obs.sceneitem"] = function(...)
-- Scene item and crop filter management. This is the proven part of the original script
-- (nested-scene search, transform-crop to crop-filter conversion, bounding box conversion,
-- release), restructured into an object so it holds no globals. What changed:
--   * a source whose size is still 0 (ScreenCaptureKit before its first frame) is attached
--     but not set up; poll_size() finishes the setup when the real size arrives
--   * the camera size and the user's crop are exposed so the math lives in geometry.lua
local obs = obslua
local log = require("cinezoom.log")

local M = {}

M.FILTER_NAME = "cinezoom-crop"

-- Older OBS versions only have the v1 transform functions
local get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local SceneItem = {}
SceneItem.__index = SceneItem

---
---@return table scene item controller
function M.new()
    return setmetatable({
        name = "",
        source = nil,
        item = nil,
        ready = false,       -- true once the source has a size and the crop filter exists
        setup_done = false,
        is_capture = true,
        info_orig = nil,     -- transform to restore on release
        crop_orig = nil,     -- transform crop to restore on release
        converted_crop = nil, -- {l,t,r,b} transform crop we turned into a filter
        filter = nil,
        filter_temp = nil,
        filter_settings = nil,
        group_item = nil,    -- the group's own item when the capture sits inside a group (we hold a reference)
        base_w = 0, base_h = 0, -- source size before any filter
        cam_w = 0, cam_h = 0,   -- size of the picture the camera moves over
        user_crop = { x = 0, y = 0, w = 0, h = 0 }, -- crop already applied by the user, in source pixels
        written = nil,
    }, SceneItem)
end

---
-- Breadth-first search for the scene item of `name`, starting at the current scene and
-- looking into nested scenes and groups. Returns an item with its own reference, or nil.
-- When the item was found inside a group, the group's item in its parent scene comes second
-- (also with its own reference).
local function find_scene_item_by_name(root_scene, name)
    local queue = { { scene = root_scene } }

    -- Entries still waiting hold a reference to their group item
    local function drop(entries)
        for _, e in ipairs(entries) do
            if e.group_item ~= nil then
                obs.obs_sceneitem_release(e.group_item)
            end
        end
    end

    while #queue > 0 do
        local entry = table.remove(queue, 1)
        local s = entry.scene
        log.debug("Looking in scene '%s'", obs.obs_source_get_name(obs.obs_scene_get_source(s)))

        -- Check if the current scene has the target scene item
        local found = obs.obs_scene_find_source(s, name)
        if found ~= nil then
            log.debug("Found sceneitem '%s'", name)
            obs.obs_sceneitem_addref(found)
            drop(queue)
            return found, entry.group_item
        end

        -- If the current scene has nested scenes, enqueue them for later examination
        local all_items = obs.obs_scene_enum_items(s)
        if all_items then
            for _, item in pairs(all_items) do
                local nested = obs.obs_sceneitem_get_source(item)
                if nested ~= nil then
                    if obs.obs_source_is_scene(nested) then
                        queue[#queue + 1] = { scene = obs.obs_scene_from_source(nested) }
                    elseif obs.obs_source_is_group(nested) then
                        obs.obs_sceneitem_addref(item)
                        queue[#queue + 1] = { scene = obs.obs_group_from_source(nested), group_item = item }
                    end
                end
            end
            obs.sceneitem_list_release(all_items)
        end
        drop({ entry })
    end

    return nil
end

---
-- Undo everything we changed and let go of all OBS references
function SceneItem:release()
    self.ready = false
    self.setup_done = false
    self.converted_crop = nil
    self.written = nil

    if self.item ~= nil then
        if self.filter ~= nil and self.source ~= nil then
            log.debug("Zoom crop filter removed")
            obs.obs_source_filter_remove(self.source, self.filter)
        end
        if self.filter_temp ~= nil and self.source ~= nil then
            log.debug("Conversion crop filter removed")
            obs.obs_source_filter_remove(self.source, self.filter_temp)
        end

        if self.info_orig ~= nil then
            log.debug("Transform info reset back to original")
            set_info(self.item, self.info_orig)
        end
        if self.crop_orig ~= nil then
            log.debug("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(self.item, self.crop_orig)
        end

        obs.obs_sceneitem_release(self.item)
    end
    if self.group_item ~= nil then
        obs.obs_sceneitem_release(self.group_item)
    end

    if self.filter ~= nil then
        obs.obs_source_release(self.filter)
    end
    if self.filter_temp ~= nil then
        obs.obs_source_release(self.filter_temp)
    end
    if self.filter_settings ~= nil then
        obs.obs_data_release(self.filter_settings)
    end
    if self.source ~= nil then
        obs.obs_source_release(self.source)
    end

    self.item, self.source, self.group_item = nil, nil, nil
    self.filter, self.filter_temp, self.filter_settings = nil, nil, nil
    self.info_orig, self.crop_orig = nil, nil
    self.base_w, self.base_h, self.cam_w, self.cam_h = 0, 0, 0, 0
end

---
-- Source size before filters. At load time some sources only answer through
-- obs_source_get_width, so that is the fallback until our own filter exists.
function SceneItem:base_size()
    local w = obs.obs_source_get_base_width(self.source)
    local h = obs.obs_source_get_base_height(self.source)
    if (w == 0 or h == 0) and not self.setup_done then
        w = obs.obs_source_get_width(self.source)
        h = obs.obs_source_get_height(self.source)
    end
    return w, h
end

---
-- Find the scene item for `name` in the current scene and prepare it for zooming.
---@param name string Source name
---@param is_capture function|nil classify(source) -> boolean, true for real display captures
---@return boolean attached
function SceneItem:attach(name, is_capture)
    self:release()
    self.name = name

    -- Get a matching source we can use for zooming in the current scene
    log.debug("Finding sceneitem for Zoom Source '%s'", name)
    local source = obs.obs_get_source_by_name(name)
    if source == nil then
        log.warn("Zoom source '%s' does not exist.", name)
        return false
    end

    local item, group_item = nil, nil
    local scene_source = obs.obs_frontend_get_current_scene()
    if scene_source ~= nil then
        -- Start at the current scene and use a BFS to look into any nested scenes
        item, group_item = find_scene_item_by_name(obs.obs_scene_from_source(scene_source), name)
        obs.obs_source_release(scene_source)
    end

    if item == nil then
        log.warn("Source '%s' is not part of the current scene hierarchy. " ..
            "Try selecting a different zoom source or switching scenes.", name)
        obs.obs_source_release(source)
        return false
    end

    self.source = source
    self.item = item
    self.group_item = group_item
    self.is_capture = is_capture == nil or is_capture(source)

    -- Capture the original settings so we can restore them later
    self.info_orig = obs.obs_transform_info()
    get_info(item, self.info_orig)
    self.crop_orig = obs.obs_sceneitem_crop()
    obs.obs_sceneitem_get_crop(item, self.crop_orig)

    if not self.is_capture then
        -- Non-display-capture sources don't correctly report crop values
        self.crop_orig.left, self.crop_orig.top, self.crop_orig.right, self.crop_orig.bottom = 0, 0, 0, 0
    end

    self:try_setup()
    return true
end

---
-- Sum of the non-relative crop filters the user already has (ours are skipped).
-- Returns nil if there are none.
function SceneItem:scan_user_crop()
    local crop = nil
    local filters = obs.obs_source_enum_filters(self.source)
    if filters == nil then
        return nil
    end

    for _, f in pairs(filters) do
        if obs.obs_source_get_id(f) == "crop_filter" then
            local fname = obs.obs_source_get_name(f)
            if fname ~= M.FILTER_NAME and fname ~= "temp_" .. M.FILTER_NAME then
                local settings = obs.obs_source_get_settings(f)
                if settings ~= nil then
                    if not obs.obs_data_get_bool(settings, "relative") then
                        crop = crop or { x = 0, y = 0, w = 0, h = 0 }
                        crop.x = crop.x + obs.obs_data_get_int(settings, "left")
                        crop.y = crop.y + obs.obs_data_get_int(settings, "top")
                        crop.w = crop.w + obs.obs_data_get_int(settings, "cx")
                        crop.h = crop.h + obs.obs_data_get_int(settings, "cy")
                        log.debug("Found existing non-relative crop/pad filter (%s)", fname)
                    else
                        log.warn("Found existing relative crop/pad filter (%s). " ..
                            "This will cause issues with zooming. Convert to non-relative settings instead.", fname)
                    end
                    obs.obs_data_release(settings)
                end
            end
        end
    end

    obs.source_list_release(filters)
    return crop
end

---
-- One-time setup once the source size is known: convert the transform to a bounding box,
-- turn a transform crop into a crop filter, and create our own crop filter.
function SceneItem:setup()
    local bw, bh = self:base_size()
    local item = self.item

    local user_crop = self:scan_user_crop()
    local c = self.crop_orig

    -- If the user has a transform crop set, we need to convert it into a crop filter so that
    -- it works correctly with zooming. Ideally the user does this manually.
    if not user_crop and (c.left ~= 0 or c.top ~= 0 or c.right ~= 0 or c.bottom ~= 0) then
        log.debug("Creating new crop filter")
        local settings = obs.obs_data_create()
        obs.obs_data_set_bool(settings, "relative", false)
        obs.obs_data_set_int(settings, "left", c.left)
        obs.obs_data_set_int(settings, "top", c.top)
        obs.obs_data_set_int(settings, "cx", bw - (c.left + c.right))
        obs.obs_data_set_int(settings, "cy", bh - (c.top + c.bottom))
        self.filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. M.FILTER_NAME, settings)
        obs.obs_source_filter_add(self.source, self.filter_temp)
        obs.obs_data_release(settings)
        self.converted_crop = { l = c.left, t = c.top, r = c.right, b = c.bottom }

        -- Clear out the transform crop
        local cleared = obs.obs_sceneitem_crop()
        cleared.left, cleared.top, cleared.right, cleared.bottom = 0, 0, 0, 0
        obs.obs_sceneitem_set_crop(item, cleared)

        log.warn("Found existing transform crop. This may cause issues with zooming. " ..
            "It has been converted to a crop/pad filter instead. " ..
            "If you have issues with your layout consider making the filter manually.")
    end

    -- Convert a plain transform into a bounding box one we can zoom inside of.
    -- The box is sized from the picture AFTER the crop, so the layout does not change.
    local info = obs.obs_transform_info()
    get_info(item, info)
    if info.bounds_type == obs.OBS_BOUNDS_NONE then
        local pw, ph = bw, bh
        if user_crop then
            pw, ph = user_crop.w, user_crop.h
        elseif self.converted_crop then
            local cc = self.converted_crop
            pw, ph = bw - (cc.l + cc.r), bh - (cc.t + cc.b)
        end
        info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
        info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)
        info.bounds.x = pw * info.scale.x
        info.bounds.y = ph * info.scale.y
        set_info(item, info)

        log.warn("Found existing non-boundingbox transform. This may cause issues with zooming. " ..
            "It has been converted to a bounding box scaling transform instead. " ..
            "If you have issues with your layout consider making the transform use a bounding box manually.")
    end

    -- Get or create our crop filter that we change during zoom
    self.filter = obs.obs_source_get_filter_by_name(self.source, M.FILTER_NAME)
    if self.filter == nil then
        self.filter_settings = obs.obs_data_create()
        obs.obs_data_set_bool(self.filter_settings, "relative", false)
        self.filter = obs.obs_source_create_private("crop_filter", M.FILTER_NAME, self.filter_settings)
        obs.obs_source_filter_add(self.source, self.filter)
    else
        self.filter_settings = obs.obs_source_get_settings(self.filter)
    end
    obs.obs_source_filter_set_order(self.source, self.filter, obs.OBS_ORDER_MOVE_BOTTOM)

    self.setup_done = true
end

---
-- Recompute base size, the user's crop and the camera size from the live source
function SceneItem:recompute()
    local bw, bh = self:base_size()
    self.base_w, self.base_h = bw, bh

    local crop = self:scan_user_crop()
    if crop then
        self.user_crop = crop
    elseif self.converted_crop then
        local cc = self.converted_crop
        self.user_crop = { x = cc.l, y = cc.t, w = bw - (cc.l + cc.r), h = bh - (cc.t + cc.b) }
    else
        self.user_crop = { x = 0, y = 0, w = bw, h = bh }
    end
    self.cam_w, self.cam_h = self.user_crop.w, self.user_crop.h

    log.debug("Source size %dx%d, camera %dx%d (user crop at %d,%d)",
        bw, bh, self.cam_w, self.cam_h, self.user_crop.x, self.user_crop.y)

    -- Start from the full picture
    self.written = nil
    self:set_crop({ x = 0, y = 0, w = self.cam_w, h = self.cam_h })
end

---
-- Finish setup if the source has a size yet. Returns true when ready.
function SceneItem:try_setup()
    if self.item == nil then
        return false
    end
    local w, h = self:base_size()
    if w == 0 or h == 0 then
        log.debug("Source size is still 0, waiting for the first frame")
        return false
    end
    if not self.setup_done then
        self:setup()
    end
    self:recompute()
    self.ready = true
    return true
end

---
-- Call every tick. Finishes a deferred setup and notices a changed source size.
---@return boolean changed True when the size became known or changed (callers re-resolve the display)
function SceneItem:poll_size()
    if self.item == nil then
        return false
    end
    if not self.ready then
        return self:try_setup()
    end
    local w = obs.obs_source_get_base_width(self.source)
    local h = obs.obs_source_get_base_height(self.source)
    if w > 0 and h > 0 and (w ~= self.base_w or h ~= self.base_h) then
        log.info("Source size changed to %dx%d", w, h)
        self:recompute()
        return true
    end
    return false
end

---
-- Write the crop filter. Values are floored here and only here.
---@param rect table {x, y, w, h} in camera space
function SceneItem:set_crop(rect)
    if self.filter == nil or self.filter_settings == nil then
        return
    end
    local l, t = math.floor(rect.x), math.floor(rect.y)
    local w, h = math.max(1, math.floor(rect.w)), math.max(1, math.floor(rect.h))

    local last = self.written
    if last and last.l == l and last.t == t and last.w == w and last.h == h then
        return -- unchanged, skip the call into OBS
    end
    self.written = { l = l, t = t, w = w, h = h }

    obs.obs_data_set_int(self.filter_settings, "left", l)
    obs.obs_data_set_int(self.filter_settings, "top", t)
    obs.obs_data_set_int(self.filter_settings, "cx", w)
    obs.obs_data_set_int(self.filter_settings, "cy", h)
    obs.obs_source_update(self.filter, self.filter_settings)
end

---
-- Human readable lines about the item, for Diagnose
---@return table lines
function SceneItem:describe()
    local lines = {}
    if self.source == nil then
        return { "no scene item attached" }
    end
    lines[#lines + 1] = string.format("source: %s (id %s)", self.name, tostring(obs.obs_source_get_id(self.source)))
    local okj, json = pcall(function()
        local s = obs.obs_source_get_settings(self.source)
        local j = obs.obs_data_get_json(s)
        obs.obs_data_release(s)
        return j
    end)
    lines[#lines + 1] = "source settings: " .. (okj and tostring(json) or "(unavailable)")
    lines[#lines + 1] = string.format("base size: %dx%d, camera size: %dx%d, ready: %s",
        self.base_w, self.base_h, self.cam_w, self.cam_h, tostring(self.ready))
    lines[#lines + 1] = string.format("user crop: x=%d y=%d w=%d h=%d",
        self.user_crop.x, self.user_crop.y, self.user_crop.w, self.user_crop.h)
    lines[#lines + 1] = "transform crop converted to filter: " .. tostring(self.converted_crop ~= nil)

    local names = {}
    local filters = obs.obs_source_enum_filters(self.source)
    if filters ~= nil then
        for _, f in pairs(filters) do
            names[#names + 1] = obs.obs_source_get_name(f) .. " (" .. obs.obs_source_get_id(f) .. ")"
        end
        obs.source_list_release(filters)
    end
    lines[#lines + 1] = "filters: " .. (#names > 0 and table.concat(names, ", ") or "none")

    if self.item ~= nil then
        local info = obs.obs_transform_info()
        get_info(self.item, info)
        lines[#lines + 1] = string.format(
            "transform: pos=(%.1f,%.1f) scale=(%.3f,%.3f) rot=%.1f bounds_type=%s bounds=(%.1f,%.1f)",
            info.pos.x, info.pos.y, info.scale.x, info.scale.y, info.rot,
            tostring(info.bounds_type), info.bounds.x, info.bounds.y)
    end
    return lines
end

return M
end

package.preload["cinezoom.obs.sources"] = function(...)
-- Capture-source knowledge: which source ids we can follow the mouse on, and how to find
-- which display (position + size in MOUSE units) a given capture source is showing.
local obs = obslua
local log = require("cinezoom.log")
local geometry = require("cinezoom.geometry")

local M = {}

-- Dropdown value meaning "no zoom source selected"
M.NONE = "cinezoom-none"

-- Capture source ids per platform (ffi.os names).
--   prop/ptype: the source property that picks the display, used for the name lookup
--   no_mouse:   the mouse position is not visible to us, so only a manual override works
local KINDS = {
    OSX = {
        { id = "screen_capture", prop = "display_uuid", ptype = "string" },
        { id = "display_capture", prop = "display", ptype = "int" },
    },
    Windows = {
        { id = "monitor_capture", prop = "monitor_id", ptype = "string" },
    },
    Linux = {
        { id = "xshm_input", prop = "screen", ptype = "int" },
        { id = "pipewire-desktop-capture-source", no_mouse = true },
    },
}

---
-- Description of a capture source id, or nil if it is not a capture source on this OS
---@param id string
---@param os_name string
---@return table|nil
function M.capture_info(id, os_name)
    for _, kind in ipairs(KINDS[os_name] or {}) do
        if kind.id == id then
            return kind
        end
    end
    return nil
end

---
-- True if the source id is a display capture source on this OS.
-- (The original script returned the opposite when "allow all sources" was off.)
---@return boolean
function M.is_capture(id, os_name)
    return M.capture_info(id, os_name) ~= nil
end

---
-- Fill the Zoom Source dropdown
---@param list any obs property list
---@param os_name string
---@param allow_all boolean List every source, not only captures
function M.populate(list, os_name, allow_all)
    obs.obs_property_list_clear(list)
    obs.obs_property_list_add_string(list, "<None>", M.NONE)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            if allow_all or M.is_capture(obs.obs_source_get_id(source), os_name) then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end
end

---
-- Find the list-item name of the display a capture source points at.
-- Returns nil if the source has no such property or the value is not in the list.
local function find_display_name(source, kind, settings)
    if not kind.prop then
        return nil
    end
    local props = obs.obs_source_properties(source)
    if props == nil then
        return nil
    end

    local found = nil
    local prop = obs.obs_properties_get(props, kind.prop)
    if prop ~= nil then
        local to_match
        if kind.ptype == "string" then
            to_match = obs.obs_data_get_string(settings, kind.prop)
        else
            to_match = obs.obs_data_get_int(settings, kind.prop)
        end

        -- Items are 0 .. count-1 (the original looped to count and read one past the end)
        for i = 0, obs.obs_property_list_item_count(prop) - 1 do
            local value
            if kind.ptype == "string" then
                value = obs.obs_property_list_item_string(prop, i)
            else
                value = obs.obs_property_list_item_int(prop, i)
            end
            if value == to_match then
                found = obs.obs_property_list_item_name(prop, i)
                break
            end
        end
    end

    obs.obs_properties_destroy(props)
    return found
end

local function copy_display(d, method)
    return {
        x = d.x, y = d.y, w = d.w, h = d.h,
        px_w = d.px_w or d.w, px_h = d.px_h or d.h,
        uuid = d.uuid, main = d.main, id = d.id,
        scale_x = d.scale_x, scale_y = d.scale_y,
        method = method,
    }
end

---
-- Work out which display a source is capturing.
-- Order: manual override, macOS ScreenCaptureKit UUID, legacy macOS index,
-- display-name parse. Logs a WARN (always visible) if nothing works.
---@param source any The OBS source (may be nil)
---@param ctx table {os, backend, override = {enabled,x,y,w,h,sx,sy}}
---@return table|nil display {x,y,w,h,px_w,px_h,method,...}
---@return string note The method used, or the reason it failed
function M.resolve_display(source, ctx)
    local ov = ctx.override
    if ov and ov.enabled then
        if ov.w > 0 and ov.h > 0 then
            return {
                x = ov.x, y = ov.y, w = ov.w, h = ov.h, px_w = ov.w, px_h = ov.h,
                scale_x = ov.sx > 0 and ov.sx or nil,
                scale_y = ov.sy > 0 and ov.sy or nil,
                method = "manual override",
            }, "manual override"
        end
        log.warn("Manual source position is on but Width/Height are 0, ignoring it.")
    end

    if source == nil then
        return nil, "no zoom source"
    end

    local id = obs.obs_source_get_id(source)
    local kind = M.capture_info(id, ctx.os)
    if not kind then
        log.warn("Zoom source '%s' is not a display capture (%s). " ..
            "Enable 'Manual source position' and enter its size and position.", obs.obs_source_get_name(source), tostring(id))
        return nil, "not a capture source"
    end
    if kind.no_mouse then
        log.warn("%s sources do not expose the mouse position. Use 'Manual source position' " ..
            "and the remote mouse listener.", id)
        return nil, "no mouse access for this source type"
    end

    local displays = nil
    if ctx.backend and ctx.backend.displays then
        local okd, list = pcall(ctx.backend.displays)
        displays = okd and list or nil
    end

    local settings = obs.obs_source_get_settings(source)
    local result, note

    if settings ~= nil and displays ~= nil and ctx.os == "OSX" then
        if id == "screen_capture" then
            -- ScreenCaptureKit: type 0 = display, 1 = window, 2 = application
            if obs.obs_data_get_int(settings, "type") ~= 0 then
                obs.obs_data_release(settings)
                log.warn("Window/application capture has no fixed display. " ..
                    "Enable 'Manual source position' and enter the display's position and size.")
                return nil, "window/application capture needs a manual override"
            end
            local uuid = obs.obs_data_get_string(settings, "display_uuid")
            for _, d in ipairs(displays) do
                if (uuid == "" and d.main) or geometry.uuid_eq(uuid, d.uuid) then
                    result, note = d, uuid == "" and "main display (no uuid set)" or "display uuid"
                    break
                end
            end
        else
            -- Legacy display_capture: uuid if the source has one, otherwise the display index
            local uuid = obs.obs_data_get_string(settings, "display_uuid")
            if uuid ~= "" then
                for _, d in ipairs(displays) do
                    if geometry.uuid_eq(uuid, d.uuid) then
                        result, note = d, "display uuid"
                        break
                    end
                end
            end
            if not result then
                result = displays[obs.obs_data_get_int(settings, "display") + 1]
                note = "display index"
            end
        end
    end

    if result then
        obs.obs_data_release(settings)
        return copy_display(result, note), note
    end

    -- Last resort: parse "WxH @ x,y" out of the display's name in the property list
    if settings ~= nil then
        local name = find_display_name(source, kind, settings)
        obs.obs_data_release(settings)
        local rect = name and geometry.parse_display_name(name)
        if rect then
            if ctx.os == "OSX" then
                local main_h
                for _, d in ipairs(displays or {}) do
                    if d.main then main_h = d.h end
                end
                if main_h then
                    rect = geometry.cocoa_rect_to_cg(rect, main_h)
                end
            end
            rect.method = "display name"
            return copy_display(rect, "display name"), "display name"
        end
    end

    log.warn("Could not work out which display '%s' captures, so mouse following is disabled. " ..
        "Run Diagnose, or enable 'Manual source position'.", obs.obs_source_get_name(source))
    return nil, "no display match"
end

return M
end

package.preload["cinezoom.platform.ffi_util"] = function(...)
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
end

package.preload["cinezoom.platform"] = function(...)
-- Picks the mouse backend for the current OS.
local M = {}

local override = nil
local override_os = nil

---
-- Tests (and the smoke test) can force a backend table or a constructor,
-- and optionally pretend to run on another OS (ffi.os names: "OSX", "Windows", "Linux")
---@param b table|function|nil
---@param os_name string|nil
function M.set_override(b, os_name)
    override = b
    override_os = os_name
end

---
-- The OS name (ffi.os) the script is running on
---@return string
function M.os_name()
    if override_os then
        return override_os
    end
    local okf, ffi = pcall(require, "ffi")
    return okf and ffi.os or "Other"
end

---
-- Create the backend for the running platform
---@param os_name string|nil Defaults to ffi.os
---@return table backend
function M.get(os_name)
    if override ~= nil then
        return type(override) == "function" and override() or override
    end

    os_name = os_name or M.os_name()

    local mod
    if os_name == "OSX" then
        mod = "cinezoom.platform.macos"
    elseif os_name == "Windows" then
        mod = "cinezoom.platform.windows"
    elseif os_name == "Linux" then
        mod = "cinezoom.platform.x11"
    else
        mod = "cinezoom.platform.null"
    end

    local okm, backend = pcall(function() return require(mod).new() end)
    if okm and backend then
        return backend
    end
    return require("cinezoom.platform.null").new("backend failed to initialise: " .. tostring(backend))
end

return M
end

package.preload["cinezoom.platform.macos"] = function(...)
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
end

package.preload["cinezoom.platform.null"] = function(...)
-- Backend used when no real one is available: every query returns nil,
-- so the script keeps running (zoom by hotkey still works, following does not).
local M = {}

function M.new(reason)
    return {
        name = "null",
        ok = false,
        reason = reason or "no mouse backend for this platform",
        symbols = {},
        mouse = function() return nil end,
        displays = function() return nil end,
        buttons = function() return false, nil end,
        key_activity = function() return nil end,
        close = function() end,
    }
end

return M
end

package.preload["cinezoom.platform.windows"] = function(...)
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
end

package.preload["cinezoom.platform.x11"] = function(...)
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
end

package.preload["cinezoom.remote"] = function(...)
-- Optional remote mouse listener: a UDP socket that receives "x y" text messages from a
-- companion app (https://github.com/BlankSourceCode/obs-zoom-to-mouse-remote).
-- Needs the ljsocket library; without it the feature is simply unavailable.
local log = require("cinezoom.log")

local M = {}

local available, socket = pcall(require, "ljsocket")
M.available = available

---
---@return table remote
function M.new()
    return { server = nil, mouse = nil, last_poll = 0 }
end

function M.start(r, port)
    if not available or r.server then
        return false
    end
    local ok, err = pcall(function()
        local address = socket.find_first_address("*", port)
        local server = socket.create("inet", "dgram", "udp")
        if server == nil then
            error("could not create the socket")
        end
        server:set_option("reuseaddr", 1)
        server:set_blocking(false)
        server:bind(address, port)
        r.server = server
    end)
    if not ok then
        log.warn("Could not start the remote mouse listener on port %s: %s", tostring(port), tostring(err))
        return false
    end
    log.info("Remote mouse listener on port %d", port)
    return true
end

function M.stop(r)
    if r.server ~= nil then
        log.info("Remote mouse listener stopped")
        pcall(function() r.server:close() end)
        r.server = nil
        r.mouse = nil
    end
end

---
-- Read every pending datagram; the latest position wins
function M.poll(r)
    if not r.server then
        return
    end
    repeat
        local okr, data, status = pcall(function() return r.server:receive_from() end)
        if not okr then
            log.warn("Remote mouse listener error: %s", tostring(data))
            return
        end
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                if not r.mouse then
                    log.info("Remote mouse client connected")
                end
                r.mouse = { x = tonumber(sx, 10), y = tonumber(sy, 10) }
            end
        elseif status ~= "timeout" and status ~= nil then
            log.warn("Remote mouse listener: %s", tostring(status))
        end
    until data == nil
end

return M
end

package.preload["cinezoom.settings"] = function(...)
-- Settings: defaults, reading them into a plain table, and the properties (UI) panel.
local obs = obslua
local camera = require("cinezoom.camera")
local sources = require("cinezoom.obs.sources")
local remote = require("cinezoom.remote")

local M = {}

---
-- Defaults for a fresh script
function M.defaults(s)
    obs.obs_data_set_default_double(s, "zoom_value", 2)
    obs.obs_data_set_default_string(s, "motion_preset", "mellow")
    obs.obs_data_set_default_double(s, "motion_stiffness", 120)
    obs.obs_data_set_default_bool(s, "follow", true)
    obs.obs_data_set_default_bool(s, "follow_outside_bounds", false)
    obs.obs_data_set_default_int(s, "follow_deadzone", 40)
    obs.obs_data_set_default_bool(s, "allow_all_sources", false)

    obs.obs_data_set_default_bool(s, "auto_enabled", false)
    obs.obs_data_set_default_double(s, "auto_idle", 2.5)
    obs.obs_data_set_default_double(s, "auto_min_hold", 0.8)
    obs.obs_data_set_default_bool(s, "auto_typing", false)
    obs.obs_data_set_default_bool(s, "auto_fast_out", false)

    obs.obs_data_set_default_bool(s, "use_override", false)
    obs.obs_data_set_default_int(s, "override_x", 0)
    obs.obs_data_set_default_int(s, "override_y", 0)
    obs.obs_data_set_default_int(s, "override_w", 1920)
    obs.obs_data_set_default_int(s, "override_h", 1080)
    obs.obs_data_set_default_double(s, "override_sx", 0)
    obs.obs_data_set_default_double(s, "override_sy", 0)

    obs.obs_data_set_default_bool(s, "use_socket", false)
    obs.obs_data_set_default_int(s, "socket_port", 12345)
    obs.obs_data_set_default_int(s, "socket_poll", 10)

    -- Click effects: everything is off until switched on
    obs.obs_data_set_default_bool(s, "fx_sound_enabled", false)
    obs.obs_data_set_default_int(s, "fx_sound_volume", 50)
    obs.obs_data_set_default_bool(s, "fx_sound_monitor", false)
    obs.obs_data_set_default_string(s, "fx_sound_file", "")
    obs.obs_data_set_default_bool(s, "fx_ripple_enabled", false)
    obs.obs_data_set_default_int(s, "fx_ripple_color", 0xFFFF8D4C) -- #4C8DFF, stored as 0xAABBGGRR
    obs.obs_data_set_default_int(s, "fx_ripple_size", 72)
    obs.obs_data_set_default_double(s, "fx_ripple_duration", 0.5)
    obs.obs_data_set_default_int(s, "fx_ripple_thickness", 5)
    obs.obs_data_set_default_int(s, "fx_ripple_opacity", 85)
    obs.obs_data_set_default_bool(s, "fx_ripple_zoom_scale", true)
    obs.obs_data_set_default_string(s, "fx_ripple_file", "")
    obs.obs_data_set_default_bool(s, "fx_only_inside", true)
    obs.obs_data_set_default_bool(s, "fx_only_zoomed", false)

    obs.obs_data_set_default_bool(s, "debug_logs", false)
end

---
-- Read the settings into a plain table
---@return table cfg
function M.read(s)
    return {
        source = obs.obs_data_get_string(s, "source"),
        zoom = obs.obs_data_get_double(s, "zoom_value"),
        preset = obs.obs_data_get_string(s, "motion_preset"),
        custom_k = obs.obs_data_get_double(s, "motion_stiffness"),
        follow = obs.obs_data_get_bool(s, "follow"),
        follow_outside = obs.obs_data_get_bool(s, "follow_outside_bounds"),
        deadzone = obs.obs_data_get_int(s, "follow_deadzone") / 100,
        allow_all = obs.obs_data_get_bool(s, "allow_all_sources"),
        auto = {
            enabled = obs.obs_data_get_bool(s, "auto_enabled"),
            idle_timeout = obs.obs_data_get_double(s, "auto_idle"),
            min_hold = obs.obs_data_get_double(s, "auto_min_hold"),
            zoom_on_typing = obs.obs_data_get_bool(s, "auto_typing"),
            zoom_out_on_fast = obs.obs_data_get_bool(s, "auto_fast_out"),
        },
        override = {
            enabled = obs.obs_data_get_bool(s, "use_override"),
            x = obs.obs_data_get_int(s, "override_x"),
            y = obs.obs_data_get_int(s, "override_y"),
            w = obs.obs_data_get_int(s, "override_w"),
            h = obs.obs_data_get_int(s, "override_h"),
            sx = obs.obs_data_get_double(s, "override_sx"),
            sy = obs.obs_data_get_double(s, "override_sy"),
        },
        socket = {
            enabled = obs.obs_data_get_bool(s, "use_socket"),
            port = obs.obs_data_get_int(s, "socket_port"),
            poll = obs.obs_data_get_int(s, "socket_poll"),
        },
        fx = {
            sound = {
                enabled = obs.obs_data_get_bool(s, "fx_sound_enabled"),
                volume = obs.obs_data_get_int(s, "fx_sound_volume"),
                monitor = obs.obs_data_get_bool(s, "fx_sound_monitor"),
                file = obs.obs_data_get_string(s, "fx_sound_file"),
            },
            ripple = {
                enabled = obs.obs_data_get_bool(s, "fx_ripple_enabled"),
                color = obs.obs_data_get_int(s, "fx_ripple_color"),
                size = math.max(1, obs.obs_data_get_int(s, "fx_ripple_size")),
                duration = obs.obs_data_get_double(s, "fx_ripple_duration"),
                thickness = obs.obs_data_get_int(s, "fx_ripple_thickness"),
                opacity = obs.obs_data_get_int(s, "fx_ripple_opacity") / 100,
                zoom_scale = obs.obs_data_get_bool(s, "fx_ripple_zoom_scale"),
                file = obs.obs_data_get_string(s, "fx_ripple_file"),
            },
            only_inside = obs.obs_data_get_bool(s, "fx_only_inside"),
            only_zoomed = obs.obs_data_get_bool(s, "fx_only_zoomed"),
        },
        debug = obs.obs_data_get_bool(s, "debug_logs"),
    }
end

---
-- Spring stiffness for the chosen motion preset
---@return number
function M.stiffness(cfg)
    if cfg.preset == "custom" then
        return math.max(1, cfg.custom_k)
    end
    return camera.PRESETS[cfg.preset] or camera.PRESETS.mellow
end

---
-- True if the two override tables differ
function M.override_changed(a, b)
    for _, k in ipairs({ "enabled", "x", "y", "w", "h", "sx", "sy" }) do
        if a[k] ~= b[k] then
            return true
        end
    end
    return false
end

---
-- Build the properties panel
---@param ctx table {os, on_refresh, on_diagnose, on_help, on_fx_test}
---@return any props
function M.properties(ctx)
    local props = obs.obs_properties_create()

    -- Source
    local src = obs.obs_properties_create()
    local source_list = obs.obs_properties_add_list(src, "source", "Zoom Source",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    local allow_all = obs.obs_properties_add_bool(src, "allow_all_sources", "Allow any zoom source ")
    obs.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")
    local cfg_now = ctx.cfg and ctx.cfg() or {}
    sources.populate(source_list, ctx.os, cfg_now.allow_all or false)
    local refresh = obs.obs_properties_add_button(src, "refresh", "Refresh zoom sources", function()
        sources.populate(source_list, ctx.os, ctx.cfg and ctx.cfg().allow_all or false)
        ctx.on_refresh()
        return true
    end)
    obs.obs_property_set_long_description(refresh,
        "Re-populate the Zoom Sources dropdown and look up the display again")
    obs.obs_property_set_modified_callback(allow_all, function(_, _, settings)
        sources.populate(source_list, ctx.os, obs.obs_data_get_bool(settings, "allow_all_sources"))
        return true
    end)
    obs.obs_properties_add_group(props, "grp_source", "Source", obs.OBS_GROUP_NORMAL, src)

    -- Zoom
    local zoom = obs.obs_properties_create()
    obs.obs_properties_add_float(zoom, "zoom_value", "Zoom Factor", 1, 5, 0.1)
    obs.obs_properties_add_group(props, "grp_zoom", "Zoom", obs.OBS_GROUP_NORMAL, zoom)

    -- Motion
    local motion = obs.obs_properties_create()
    local preset = obs.obs_properties_add_list(motion, "motion_preset", "Motion",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(preset, "Slow", "slow")
    obs.obs_property_list_add_string(preset, "Mellow", "mellow")
    obs.obs_property_list_add_string(preset, "Quick", "quick")
    obs.obs_property_list_add_string(preset, "Rapid", "rapid")
    obs.obs_property_list_add_string(preset, "Custom", "custom")
    local stiffness = obs.obs_properties_add_float(motion, "motion_stiffness", "Custom stiffness", 10, 1000, 10)
    obs.obs_property_set_long_description(stiffness, "Spring stiffness for the Custom motion (higher is snappier)")
    obs.obs_property_set_visible(stiffness, (cfg_now.preset or "mellow") == "custom")
    obs.obs_property_set_modified_callback(preset, function(_, _, settings)
        local custom = obs.obs_data_get_string(settings, "motion_preset") == "custom"
        obs.obs_property_set_visible(stiffness, custom)
        return true
    end)
    obs.obs_properties_add_group(props, "grp_motion", "Motion", obs.OBS_GROUP_NORMAL, motion)

    -- Follow
    local follow = obs.obs_properties_create()
    local f1 = obs.obs_properties_add_bool(follow, "follow", "Auto follow mouse ")
    obs.obs_property_set_long_description(f1,
        "When enabled mouse tracking starts as soon as you zoom in, without the follow hotkey")
    local f2 = obs.obs_properties_add_bool(follow, "follow_outside_bounds", "Follow outside bounds ")
    obs.obs_property_set_long_description(f2,
        "Track the mouse even when the cursor is outside the zoom source")
    local f3 = obs.obs_properties_add_int_slider(follow, "follow_deadzone", "Deadzone (%)", 0, 90, 1)
    obs.obs_property_set_long_description(f3,
        "The view only moves when the mouse leaves this area around the view center. 0 follows every movement.")
    obs.obs_properties_add_group(props, "grp_follow", "Follow", obs.OBS_GROUP_NORMAL, follow)

    -- Auto-zoom
    local auto = obs.obs_properties_create()
    local a1 = obs.obs_properties_add_bool(auto, "auto_enabled", "Zoom automatically on click ")
    obs.obs_property_set_long_description(a1, "Zoom in on clicks and zoom out when you stop interacting")
    obs.obs_properties_add_float(auto, "auto_idle", "Zoom out after (s)", 0.5, 20, 0.1)
    obs.obs_properties_add_float(auto, "auto_min_hold", "Minimum hold (s)", 0, 10, 0.1)
    obs.obs_properties_add_bool(auto, "auto_typing", "Zoom in when typing ")
    obs.obs_properties_add_bool(auto, "auto_fast_out", "Zoom out on fast mouse movement ")
    obs.obs_properties_add_group(props, "grp_auto", "Auto-zoom", obs.OBS_GROUP_NORMAL, auto)

    -- Click sound
    local snd = obs.obs_properties_create()
    obs.obs_properties_add_int_slider(snd, "fx_sound_volume", "Volume (%)", 0, 100, 1)
    local s2 = obs.obs_properties_add_bool(snd, "fx_sound_monitor", "Also play locally (monitor) ")
    obs.obs_property_set_long_description(s2, "Also play the click through your monitoring device " ..
        "(OBS Settings > Audio > Advanced). The click always goes into the recording and stream.")
    local s3 = obs.obs_properties_add_path(snd, "fx_sound_file", "Custom sound file ", obs.OBS_PATH_FILE,
        "Audio (*.wav *.mp3 *.ogg *.flac)", nil)
    obs.obs_property_set_long_description(s3, "Leave empty for the built-in click")
    obs.obs_properties_add_group(props, "fx_sound_enabled", "Click sound ", obs.OBS_GROUP_CHECKABLE, snd)

    -- Click ripple
    local rip = obs.obs_properties_create()
    obs.obs_properties_add_color(rip, "fx_ripple_color", "Color ")
    obs.obs_properties_add_int(rip, "fx_ripple_size", "Size (px)", 20, 400, 1)
    obs.obs_properties_add_float(rip, "fx_ripple_duration", "Duration (s)", 0.1, 2.0, 0.05)
    obs.obs_properties_add_int(rip, "fx_ripple_thickness", "Ring thickness (px)", 1, 40, 1)
    obs.obs_properties_add_int_slider(rip, "fx_ripple_opacity", "Opacity (%)", 10, 100, 1)
    local r1 = obs.obs_properties_add_bool(rip, "fx_ripple_zoom_scale", "Scale with zoom ")
    obs.obs_property_set_long_description(r1, "Make the ripple larger when the view is zoomed in")
    local r2 = obs.obs_properties_add_path(rip, "fx_ripple_file", "Custom image ", obs.OBS_PATH_FILE,
        "Images (*.png *.webp *.gif *.jpg)", nil)
    obs.obs_property_set_long_description(r2, "Leave empty for the built-in ring. The color is ignored for a custom image")
    obs.obs_properties_add_group(props, "fx_ripple_enabled", "Click ripple ", obs.OBS_GROUP_CHECKABLE, rip)

    -- Click effects (shared)
    local fx = obs.obs_properties_create()
    obs.obs_properties_add_bool(fx, "fx_only_inside", "Only clicks on the captured display ")
    obs.obs_properties_add_bool(fx, "fx_only_zoomed", "Only while zoomed in ")
    local test = obs.obs_properties_add_button(fx, "fx_test_button", "Test click effects", function()
        ctx.on_fx_test()
        return false
    end)
    obs.obs_property_set_long_description(test, "Play the sound and show a ripple at the current mouse position")
    obs.obs_properties_add_group(props, "grp_fx", "Click effects", obs.OBS_GROUP_NORMAL, fx)

    -- Display override
    local override = obs.obs_properties_create()
    local o1 = obs.obs_properties_add_int(override, "override_x", "X", -20000, 20000, 1)
    obs.obs_properties_add_int(override, "override_y", "Y", -20000, 20000, 1)
    obs.obs_properties_add_int(override, "override_w", "Width", 0, 20000, 1)
    obs.obs_properties_add_int(override, "override_h", "Height", 0, 20000, 1)
    local o5 = obs.obs_properties_add_float(override, "override_sx", "Scale X ", 0, 100, 0.01)
    local o6 = obs.obs_properties_add_float(override, "override_sy", "Scale Y ", 0, 100, 0.01)
    obs.obs_property_set_long_description(o1,
        "Position and size of the display in MOUSE units (points on macOS, pixels on Windows/Linux)")
    obs.obs_property_set_long_description(o5, "0 = automatic (source size / Width). Set it for cloned or scaled sources")
    obs.obs_property_set_long_description(o6, "0 = automatic (source size / Height). Set it for cloned or scaled sources")
    obs.obs_properties_add_group(props, "use_override", "Set manual source position ",
        obs.OBS_GROUP_CHECKABLE, override)

    -- Remote mouse (only when ljsocket is installed)
    if remote.available then
        local sock = obs.obs_properties_create()
        local r1 = obs.obs_properties_add_int(sock, "socket_port", "Port ", 1024, 65535, 1)
        local r2 = obs.obs_properties_add_int(sock, "socket_poll", "Poll Delay (ms) ", 0, 1000, 1)
        obs.obs_property_set_long_description(r1, "Uncheck and re-check the listener to apply a new port")
        obs.obs_property_set_long_description(r2, "Uncheck and re-check the listener to apply a new poll delay")
        obs.obs_properties_add_group(props, "use_socket", "Enable remote mouse listener ",
            obs.OBS_GROUP_CHECKABLE, sock)
    end

    obs.obs_properties_add_button(props, "diagnose_button", "Diagnose", function()
        ctx.on_diagnose()
        return false
    end)
    obs.obs_properties_add_button(props, "help_button", "Help", function()
        ctx.on_help()
        return false
    end)
    local debug = obs.obs_properties_add_bool(props, "debug_logs", "Enable debug logging ")
    obs.obs_property_set_long_description(debug,
        "Print extra diagnostics to the script log (warnings and errors are always shown)")

    return props
end

return M
end

package.preload["cinezoom.spring"] = function(...)
-- Critically damped spring, integrated with semi-implicit Euler in small fixed substeps
-- so the motion does not depend on the frame rate.
local M = {}

local MAX_DT = 0.25       -- never integrate more than this per call (tab-outs, breakpoints)
local MAX_STEP = 1 / 240  -- substep size

---
---@param x number Initial value
---@param k number Stiffness
---@param zeta number|nil Damping ratio, 1 = critical
---@param eps number|nil Snap distance
---@return table spring
function M.new(x, k, zeta, eps)
    return { x = x, v = 0, target = x, k = k or 120, zeta = zeta or 1, eps = eps or 0.01 }
end

function M.is_settled(s)
    return math.abs(s.target - s.x) < s.eps and math.abs(s.v) < s.eps
end

---
-- Advance the spring by dt seconds and return the new value
---@return number
function M.step(s, dt)
    if not (dt > 0) then -- also rejects NaN
        return s.x
    end
    if dt > MAX_DT then
        dt = MAX_DT
    end

    local n = math.ceil(dt / MAX_STEP)
    local h = dt / n
    local c = 2 * s.zeta * math.sqrt(s.k)
    for _ = 1, n do
        local a = s.k * (s.target - s.x) - c * s.v
        s.v = s.v + a * h
        s.x = s.x + s.v * h
    end

    if M.is_settled(s) then
        s.x = s.target
        s.v = 0
    end
    return s.x
end

---
-- Jump to a value without animating
function M.snap(s, x)
    s.x = x
    s.target = x
    s.v = 0
end

return M
end

package.preload["cinezoom.version"] = function(...)
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
end

require("cinezoom.main").install(_G)
