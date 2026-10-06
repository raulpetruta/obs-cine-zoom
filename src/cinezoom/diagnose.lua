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
