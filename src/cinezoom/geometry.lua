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
