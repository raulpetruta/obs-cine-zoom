-- Studio layout math: pure functions, no OBS calls. All values are canvas pixels (fractional).
-- Two coordinate spaces are involved:
--   * the frame scene: canvas-sized, holds the capture fitted (SCALE_INNER) and centred
--   * the canvas: where the frame scene ends up once the frame item in the Studio scene is
--     scaled and moved (frame_transform), leaving room for the background around it
local M = {}

local function round(v)
    return math.floor(v + 0.5)
end

---
-- Size of a picture sw x sh scaled to fit inside bw x bh (aspect kept)
---@return number w, number h
function M.fit(sw, sh, bw, bh)
    local s = math.min(bw / sw, bh / sh)
    return sw * s, sh * s
end

---
-- Where the capture lands inside the canvas-sized frame scene: fitted, then centred
---@return table rect {x, y, w, h}
function M.frame_content(cw, ch, sw, sh)
    local w, h = M.fit(sw, sh, cw, ch)
    return { x = (cw - w) / 2, y = (ch - h) / 2, w = w, h = h }
end

---
-- Where the picture ends up on the canvas: the canvas minus the padding on every side, fitted and centred.
---@param pad_pct number Padding in percent of the shorter canvas side
---@return table rect {x, y, w, h}
function M.target_rect(cw, ch, sw, sh, pad_pct)
    local pad = pad_pct / 100 * math.min(cw, ch)
    local aw, ah = math.max(1, cw - 2 * pad), math.max(1, ch - 2 * pad)
    local w, h = M.fit(sw, sh, aw, ah)
    return { x = (cw - w) / 2, y = (ch - h) / 2, w = w, h = h }
end

---
-- Transform of the frame item (alignment top-left, bounds NONE) that maps the content rect
-- of the frame scene onto the target rect.
---@return table {scale, pos_x, pos_y}
function M.frame_transform(content, target)
    local scale = target.w / content.w
    return { scale = scale, pos_x = target.x - content.x * scale, pos_y = target.y - content.y * scale }
end

---
-- Where a frame-scene point is on the canvas
---@return number x, number y
function M.canvas_point(pt, tf)
    return tf.pos_x + pt.x * tf.scale, tf.pos_y + pt.y * tf.scale
end

---
-- The shadow image rect: the target grown by blur on every side, then moved by the offset
---@return table rect {x, y, w, h}
function M.shadow_rect(target, blur, off_x, off_y)
    return {
        x = target.x - blur + off_x, y = target.y - blur + off_y,
        w = target.w + 2 * blur, h = target.h + 2 * blur,
    }
end

---
-- Mask image: canvas aspect, at most 960 px on the long side. The corner radius is given in
-- output pixels, so it is divided by the frame scale to get frame-scene pixels.
---@return table {w, h, rect, r}
function M.mask_spec(cw, ch, content, scale, radius_px)
    local ms = math.min(1, 960 / math.max(cw, ch))
    local rect = { x = content.x * ms, y = content.y * ms, w = content.w * ms, h = content.h * ms }
    local r = math.max(0, math.min(radius_px / scale * ms, rect.w / 2, rect.h / 2))
    return { w = round(cw * ms), h = round(ch * ms), rect = rect, r = r }
end

---
-- Shadow image: a quarter of the output size is plenty for a blurred shape
---@param q number|nil Image pixels per canvas pixel
---@return table {w, h, inner, r, box}
function M.shadow_spec(target, blur, radius_px, q)
    q = q or 0.25
    return {
        w = math.ceil((target.w + 2 * blur) * q),
        h = math.ceil((target.h + 2 * blur) * q),
        inner = { x = blur * q, y = blur * q, w = target.w * q, h = target.h * q },
        r = radius_px * q,
        box = math.max(1, round(blur * q / 3)),
    }
end

return M
