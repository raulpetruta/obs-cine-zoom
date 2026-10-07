-- Studio images as RGBA strings (straight alpha, w*h*4 bytes) for png.encode: the background
-- gradient, the rounded-corner mask and the soft shadow. Pure Lua; the work is done per row into a
-- table of strings, never by concatenating per pixel, because this runs inside OBS.
local M = {}

local char, floor, sqrt = string.char, math.floor, math.sqrt
local concat = table.concat

local function clamp(v, lo, hi)
    return v < lo and lo or (v > hi and hi or v)
end

-- 0xAABBGGRR (what OBS colour properties store) -> r, g, b
local function unpack_color(c)
    return c % 256, floor(c / 256) % 256, floor(c / 65536) % 256
end

-- 4x4 ordered-dither thresholds in (0, 1), mean 0.5, so floor(v + threshold) rounds without banding
local BAYER = {
    { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 },
}

---
-- Linear gradient from c1 to c2. Angle 0 runs left to right, 90 top to bottom (y points down).
-- The ramp spans the projection of the four corners, so both colours are reached at the corners.
---@param w number
---@param h number
---@param c1 number Start colour, 0xAABBGGRR
---@param c2 number End colour, 0xAABBGGRR
---@param angle_deg number
---@return string rgba
function M.gradient_rgba(w, h, c1, c2, angle_deg)
    local r1, g1, b1 = unpack_color(c1)
    local r2, g2, b2 = unpack_color(c2)
    local a = math.rad(angle_deg)
    local dx, dy = math.cos(a), math.sin(a)
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs({ { 0, 0 }, { w, 0 }, { 0, h }, { w, h } }) do
        local v = p[1] * dx + p[2] * dy
        lo, hi = math.min(lo, v), math.max(hi, v)
    end
    local span = hi - lo
    if span < 1e-9 then span = 1 end

    local rows = {}
    for y = 0, h - 1 do
        local row = {}
        local brow = BAYER[y % 4 + 1]
        for x = 0, w - 1 do
            local t = clamp(((x + 0.5) * dx + (y + 0.5) * dy - lo) / span, 0, 1)
            local th = (brow[x % 4 + 1] + 0.5) / 16
            row[x + 1] = char(
                clamp(floor(r1 + (r2 - r1) * t + th), 0, 255),
                clamp(floor(g1 + (g2 - g1) * t + th), 0, 255),
                clamp(floor(b1 + (b2 - b1) * t + th), 0, 255), 255)
        end
        rows[y + 1] = concat(row)
    end
    return concat(rows)
end

-- Anti-aliased coverage (0..1) of a rounded rect at pixel centre (px, py), from its signed distance
local function rounded_cover(px, py, cx, cy, hx, hy, r)
    local qx = math.abs(px - cx) - (hx - r)
    local qy = math.abs(py - cy) - (hy - r)
    local mx, my = qx > 0 and qx or 0, qy > 0 and qy or 0
    local d = sqrt(mx * mx + my * my) + math.min(math.max(qx, qy), 0) - r
    return clamp(0.5 - d, 0, 1)
end

---
-- Mask for mask_filter: white and opaque inside the rounded rect, black and transparent outside.
-- RGB equals alpha everywhere, so it works whether the mask type reads the colour or the alpha.
---@param w number Image size
---@param h number
---@param rect table {x, y, w, h} of the rounded rect in image pixels
---@param r number Corner radius in image pixels
---@return string rgba
function M.rounded_mask_rgba(w, h, rect, r)
    local px = {}
    for v = 0, 255 do
        px[v] = char(v, v, v, v)
    end
    local cx, cy = rect.x + rect.w / 2, rect.y + rect.h / 2
    local hx, hy = rect.w / 2, rect.h / 2
    r = clamp(r, 0, math.min(hx, hy))

    local rows = {}
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            row[x + 1] = px[floor(rounded_cover(x + 0.5, y + 0.5, cx, cy, hx, hy, r) * 255 + 0.5)]
        end
        rows[y + 1] = concat(row)
    end
    return concat(rows)
end

-- One box blur pass along a line of n values (clamped to 0 outside), radius k, running sum
local function blur_line(src, dst, n, k)
    local win = 2 * k + 1
    local sum = 0
    for i = 1, k + 1 do
        sum = sum + (src[i] or 0)
    end
    for i = 1, n do
        dst[i] = sum / win
        local add, sub = i + k + 1, i - k
        if add <= n then sum = sum + src[add] end
        if sub >= 1 then sum = sum - src[sub] end
    end
end

---
-- Soft shadow: the rounded rect of spec.inner blurred with three box passes (close to a Gaussian).
---@param spec table From layout.shadow_spec: {w, h, inner = {x, y, w, h}, r, box}
---@param opacity number 0..1
---@param rgb table|nil {r, g, b}, black by default
---@return string rgba
function M.shadow_rgba(spec, opacity, rgb)
    local w, h = spec.w, spec.h
    local inner = spec.inner
    local cx, cy = inner.x + inner.w / 2, inner.y + inner.h / 2
    local hx, hy = inner.w / 2, inner.h / 2
    local r = clamp(spec.r, 0, math.min(hx, hy))

    local rows = {}
    for y = 1, h do
        local row = {}
        for x = 1, w do
            row[x] = rounded_cover(x - 0.5, y - 0.5, cx, cy, hx, hy, r)
        end
        rows[y] = row
    end

    local k = spec.box
    local tmp = {}
    for _ = 1, 3 do
        for y = 1, h do
            blur_line(rows[y], tmp, w, k)
            rows[y], tmp = tmp, rows[y]
        end
        local col, out = {}, {}
        for x = 1, w do
            for y = 1, h do col[y] = rows[y][x] end
            blur_line(col, out, h, k)
            for y = 1, h do rows[y][x] = out[y] end
        end
    end

    rgb = rgb or { 0, 0, 0 }
    local prefix = char(rgb[1], rgb[2], rgb[3])
    local alpha = {}
    for i = 0, 255 do
        alpha[i] = prefix .. char(i)
    end
    local out = {}
    for y = 1, h do
        local row, line = rows[y], {}
        for x = 1, w do
            line[x] = alpha[clamp(floor(row[x] * opacity * 255 + 0.5), 0, 255)]
        end
        out[y] = concat(line)
    end
    return concat(out)
end

return M
