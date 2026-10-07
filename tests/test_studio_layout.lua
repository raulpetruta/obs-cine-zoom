-- Studio layout math, including how a ripple point travels through the frame scene to the canvas.
local layout = require("cinezoom.studio.layout")
local geometry = require("cinezoom.geometry")

local B = { NONE = 0, STRETCH = 1, SCALE_INNER = 2, SCALE_OUTER = 3, SCALE_TO_WIDTH = 4,
    SCALE_TO_HEIGHT = 5, MAX_ONLY = 6 }

return function(t)
    t.test("frame_content fits a Retina capture into a 1920x1080 canvas and centres it", function()
        local c = layout.frame_content(1920, 1080, 3024, 1964)
        t.near(c.w, 1662.9, 0.1)
        t.near(c.h, 1080, 1e-9)
        t.near(c.x, 128.5, 0.1)
        t.near(c.y, 0, 1e-9)
    end)

    t.test("frame_content: a same-aspect source fills the canvas", function()
        local c = layout.frame_content(1920, 1080, 2560, 1440)
        t.near(c.x, 0, 1e-9); t.near(c.y, 0, 1e-9)
        t.near(c.w, 1920, 1e-9); t.near(c.h, 1080, 1e-9)
    end)

    t.test("target_rect insets by the padding on the limiting axis and is centred", function()
        local r = layout.target_rect(1920, 1080, 2560, 1440, 6)
        t.near(r.y, 64.8, 1e-9, "6% of 1080")
        t.near(r.h, 1080 - 2 * 64.8, 1e-9)
        t.near(r.x + r.w / 2, 960, 1e-9)
        t.near(r.y + r.h / 2, 540, 1e-9)
        -- a taller source is limited by the height, a wider one by the width
        local tall = layout.target_rect(1920, 1080, 1000, 1000, 6)
        t.near(tall.h, 1080 - 2 * 64.8, 1e-9)
        t.near(tall.x + tall.w / 2, 960, 1e-9)
        local zero = layout.target_rect(1920, 1080, 2560, 1440, 0)
        t.near(zero.w, 1920, 1e-9)
    end)

    t.test("frame_transform maps the content corners exactly onto the target corners", function()
        local content = layout.frame_content(1920, 1080, 3024, 1964)
        local target = layout.target_rect(1920, 1080, 3024, 1964, 6)
        local tf = layout.frame_transform(content, target)
        local x0, y0 = layout.canvas_point({ x = content.x, y = content.y }, tf)
        local x1, y1 = layout.canvas_point({ x = content.x + content.w, y = content.y + content.h }, tf)
        t.near(x0, target.x, 1e-9); t.near(y0, target.y, 1e-9)
        t.near(x1, target.x + target.w, 1e-9); t.near(y1, target.y + target.h, 1e-9)
    end)

    t.test("shadow_rect grows by the blur, then moves by the offset", function()
        local r = layout.shadow_rect({ x = 100, y = 50, w = 800, h = 400 }, 40, 5, 12)
        t.eq(r.x, 65); t.eq(r.y, 22); t.eq(r.w, 880); t.eq(r.h, 480)
        local s = layout.shadow_spec({ x = 100, y = 50, w = 800, h = 400 }, 40, 18)
        t.eq(s.w, 220); t.eq(s.h, 120)
        t.eq(s.inner.x, 10); t.eq(s.inner.w, 200)
        t.near(s.r, 4.5, 1e-9)
        t.eq(s.box, 3)
        t.eq(layout.shadow_spec({ x = 0, y = 0, w = 10, h = 10 }, 0, 0).box, 1, "box is at least 1")
    end)

    t.test("mask_spec converts the radius to frame pixels and clamps it", function()
        local content = layout.frame_content(1920, 1080, 3024, 1964)
        local m = layout.mask_spec(1920, 1080, content, 0.85, 18)
        t.eq(m.w, 960); t.eq(m.h, 540)
        t.near(m.rect.x, content.x / 2, 1e-9)
        t.near(m.r, 18 / 0.85 / 2, 1e-9)
        local big = layout.mask_spec(1920, 1080, content, 0.85, 5000)
        t.near(big.r, m.rect.h / 2, 1e-9, "clamped to half the short side")
        t.eq(layout.mask_spec(1920, 1080, content, 0.85, 0).r, 0)
        local small = layout.mask_spec(640, 360, { x = 0, y = 0, w = 640, h = 360 }, 1, 10)
        t.eq(small.w, 640, "a small canvas is not scaled up")
        t.near(small.r, 10, 1e-9)
    end)

    -- A click in camera space goes: camera -> frame scene (the capture item, SCALE_INNER in a
    -- canvas-sized box) -> canvas (the frame item's transform). The ripple code only does the first step.
    local function ripple_canvas_point(cam_w, cam_h, view, pad, ax, ay)
        local content = layout.frame_content(1920, 1080, cam_w, cam_h)
        local target = layout.target_rect(1920, 1080, cam_w, cam_h, pad)
        local tf = layout.frame_transform(content, target)
        local info = { pos = { x = 0, y = 0 }, scale = { x = 1, y = 1 }, alignment = 5,
            bounds_type = B.SCALE_INNER, bounds = { x = 1920, y = 1080 }, bounds_alignment = 0 }
        local rect = geometry.item_content_rect(info, view.w, view.h, B)
        local px, py = geometry.camera_to_canvas(ax, ay, view, rect)
        local x, y = layout.canvas_point({ x = px, y = py }, tf)
        return x, y, target
    end

    t.test("ripple: the camera centre lands at the target centre, zoomed out and zoomed in", function()
        local full = { x = 0, y = 0, w = 3024, h = 1964 }
        local x, y, target = ripple_canvas_point(3024, 1964, full, 6, 1512, 982)
        t.near(x, target.x + target.w / 2, 1e-6)
        t.near(y, target.y + target.h / 2, 1e-6)

        local zoomed = { x = 756, y = 491, w = 1512, h = 982 }
        x, y, target = ripple_canvas_point(3024, 1964, zoomed, 6, 1512, 982)
        t.near(x, target.x + target.w / 2, 1e-6, "view centre at zoom 2")
        t.near(y, target.y + target.h / 2, 1e-6)
    end)

    t.test("ripple: a view in a corner maps its own corner to the target corner", function()
        local view = { x = 0, y = 0, w = 1512, h = 982 } -- zoom 2, top-left corner
        local x, y, target = ripple_canvas_point(3024, 1964, view, 6, 0, 0)
        t.near(x, target.x, 1e-6); t.near(y, target.y, 1e-6)
        x, y = ripple_canvas_point(3024, 1964, view, 6, 1512, 982)
        t.near(x, target.x + target.w, 1e-6); t.near(y, target.y + target.h, 1e-6)
        -- bottom-right view
        local br = { x = 1512, y = 982, w = 1512, h = 982 }
        x, y = ripple_canvas_point(3024, 1964, br, 6, 3024, 1964)
        t.near(x, target.x + target.w, 1e-6); t.near(y, target.y + target.h, 1e-6)
    end)
end
