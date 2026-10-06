local g = require("cinezoom.geometry")

return function(t)
    t.test("secondary display offsets the mouse", function()
        local d = { x = 1920, y = -200, w = 2560, h = 1440 }
        local x, y = g.to_display_local(2000, 100, d)
        t.eq(x, 80); t.eq(y, 300)
    end)

    t.test("Retina: points scale to pixels using the source size", function()
        local d = { x = 0, y = 0, w = 1512, h = 982 }
        local x, y = g.to_source_px(756, 491, d, 3024, 1964)
        t.eq(x, 1512); t.eq(y, 982)
    end)

    t.test("source size 0 falls back to display pixel size", function()
        local d = { x = 0, y = 0, w = 1512, h = 982, px_w = 3024, px_h = 1964 }
        local x, y = g.to_source_px(756, 491, d, 0, 0)
        t.eq(x, 1512); t.eq(y, 982)
    end)

    t.test("no size info at all means scale 1", function()
        local x, y = g.to_source_px(10, 20, { x = 0, y = 0, w = 100, h = 100 }, 0, 0)
        t.eq(x, 10); t.eq(y, 20)
    end)

    t.test("manual scale override wins", function()
        local d = { x = 0, y = 0, w = 100, h = 100, scale_x = 0.5, scale_y = 0.25 }
        local x, y = g.to_source_px(100, 100, d, 400, 400)
        t.eq(x, 50); t.eq(y, 25)
    end)

    t.test("crop is subtracted AFTER scaling (Retina + user crop)", function()
        -- 2x display, user crop of 100 source pixels on the left.
        -- Mouse at 150 points = 300 px = 200 px into the cropped picture.
        -- The old script subtracted first: (150 - 100) * 2 = 100 (wrong).
        local d = { x = 0, y = 0, w = 1000, h = 1000 }
        local px, py = g.to_source_px(150, 0, d, 2000, 2000)
        local cx = g.to_camera_space(px, py, { x = 100, y = 0 })
        t.eq(cx, 200)
    end)

    t.test("view_rect centers and sizes", function()
        local r = g.view_rect(500, 400, 2, 1000, 800)
        t.eq(r.w, 500); t.eq(r.h, 400); t.eq(r.x, 250); t.eq(r.y, 200)
    end)

    t.test("view_rect clamps to the camera area", function()
        local r = g.view_rect(10, 10, 4, 1000, 800)
        t.eq(r.x, 0); t.eq(r.y, 0)
        r = g.view_rect(990, 790, 4, 1000, 800)
        t.eq(r.x, 750); t.eq(r.y, 600)
    end)

    t.test("view_rect at zoom 1 (or below) is the full rect", function()
        local r = g.view_rect(300, 300, 1, 1000, 800)
        t.eq(r.x, 0); t.eq(r.w, 1000); t.eq(r.h, 800)
        r = g.view_rect(300, 300, 0.2, 1000, 800)
        t.eq(r.w, 1000)
    end)

    t.test("camera_to_canvas maps view corners to item corners", function()
        local view = { x = 100, y = 50, w = 400, h = 200 }
        local item = { x = 10, y = 20, w = 800, h = 400 }
        local x, y = g.camera_to_canvas(100, 50, view, item)
        t.eq(x, 10); t.eq(y, 20)
        x, y = g.camera_to_canvas(500, 250, view, item)
        t.eq(x, 810); t.eq(y, 420)
    end)

    t.test("parse_display_name (Windows style)", function()
        local r = g.parse_display_name("U2790B: 3840x2160 @ -1920,0 (Primary Monitor)")
        t.eq(r.w, 3840); t.eq(r.h, 2160); t.eq(r.x, -1920); t.eq(r.y, 0)
    end)

    t.test("parse_display_name (X11 style) with spaces", function()
        local r = g.parse_display_name("Screen 1 (1920x1080 @ 1920, 0)")
        t.eq(r.x, 1920); t.eq(r.w, 1920)
    end)

    t.test("parse_display_name rejects names without geometry", function()
        t.eq(g.parse_display_name("Built-in Retina Display"), nil)
        t.eq(g.parse_display_name("LG HDR 4K"), nil)
        t.eq(g.parse_display_name("1920x1080"), nil)
        t.eq(g.parse_display_name(nil), nil)
    end)

    t.test("cocoa_rect_to_cg flips Y against the main display", function()
        -- Main 1440x900 at origin; a 1920x1080 display sitting above it.
        -- In Cocoa it is at y = 900 (bottom-left origin); in top-left space it is at y = -1080.
        local r = g.cocoa_rect_to_cg({ x = 0, y = 900, w = 1920, h = 1080 }, 900)
        t.eq(r.y, -1080); t.eq(r.h, 1080); t.eq(r.x, 0)
        -- The main display itself stays at 0
        r = g.cocoa_rect_to_cg({ x = 0, y = 0, w = 1440, h = 900 }, 900)
        t.eq(r.y, 0)
    end)

    t.test("uuid_eq is case-insensitive and rejects empties", function()
        t.truthy(g.uuid_eq("abc-DEF", "ABC-def"))
        t.truthy(not g.uuid_eq("", ""))
        t.truthy(not g.uuid_eq("a", "b"))
        t.truthy(not g.uuid_eq(nil, "a"))
    end)

    t.test("clamp tolerates hi < lo", function()
        t.eq(g.clamp(5, 0, -1), 0)
        t.eq(g.clamp(5, 0, 3), 3)
        t.eq(g.clamp(-5, 0, 3), 0)
    end)

    local B = { NONE = 0, STRETCH = 1, SCALE_INNER = 2, SCALE_OUTER = 3, SCALE_TO_WIDTH = 4,
        SCALE_TO_HEIGHT = 5, MAX_ONLY = 6 }
    local function info(o)
        local i = { pos = { x = 0, y = 0 }, scale = { x = 1, y = 1 }, rot = 0, alignment = 5,
            bounds_type = 0, bounds_alignment = 0, bounds = { x = 0, y = 0 } }
        for k, v in pairs(o) do i[k] = v end
        return i
    end
    local function rect_eq(t, r, x, y, w, h, msg)
        t.near(r.x, x, 1e-6, (msg or "rect") .. ".x"); t.near(r.y, y, 1e-6, (msg or "rect") .. ".y")
        t.near(r.w, w, 1e-6, (msg or "rect") .. ".w"); t.near(r.h, h, 1e-6, (msg or "rect") .. ".h")
    end

    t.test("align_offset covers every anchor", function()
        local function at(a) local x, y = g.align_offset(a, 100, 40); return x .. "," .. y end
        t.eq(at(0), "50,20")
        t.eq(at(5), "0,0")     -- top left
        t.eq(at(10), "100,40") -- bottom right
        t.eq(at(1), "0,20")    -- left
        t.eq(at(2), "100,20")  -- right
        t.eq(at(4), "50,0")    -- top
        t.eq(at(8), "50,40")   -- bottom
    end)

    t.test("item_content_rect: no bounds, centered and corner aligned", function()
        rect_eq(t, g.item_content_rect(info({ pos = { x = 960, y = 540 }, scale = { x = 0.5, y = 0.5 }, alignment = 0 }),
            1000, 800, B), 710, 340, 500, 400)
        rect_eq(t, g.item_content_rect(info({ pos = { x = 100, y = 100 }, alignment = 10 }), 40, 20, B), 60, 80, 40, 20)
    end)

    t.test("item_content_rect: scale inner letterboxes (bounds alignment center and top-left)", function()
        local i = info({ bounds_type = B.SCALE_INNER, bounds = { x = 1920, y = 1080 }, bounds_alignment = 0 })
        rect_eq(t, g.item_content_rect(i, 1000, 1000, B), 420, 0, 1080, 1080, "center")
        i.bounds_alignment = 5
        rect_eq(t, g.item_content_rect(i, 1000, 1000, B), 0, 0, 1080, 1080, "top-left")
        i.pos = { x = 100, y = 50 }
        rect_eq(t, g.item_content_rect(i, 1000, 1000, B), 100, 50, 1080, 1080, "offset")
    end)

    t.test("item_content_rect: stretch, to width, to height, outer, max only", function()
        local function r(bt, bounds) return g.item_content_rect(info({ bounds_type = bt, bounds = bounds }), 400, 400, B) end
        rect_eq(t, r(B.STRETCH, { x = 800, y = 600 }), 0, 0, 800, 600, "stretch")
        rect_eq(t, r(B.SCALE_TO_WIDTH, { x = 800, y = 600 }), 0, -100, 800, 800, "width")
        rect_eq(t, r(B.SCALE_TO_HEIGHT, { x = 800, y = 600 }), 100, 0, 600, 600, "height")
        rect_eq(t, r(B.SCALE_OUTER, { x = 800, y = 600 }), 0, -100, 800, 800, "outer")
        rect_eq(t, r(B.MAX_ONLY, { x = 800, y = 600 }), 200, 100, 400, 400, "max only does not enlarge")
        rect_eq(t, r(B.MAX_ONLY, { x = 200, y = 300 }), 0, 50, 200, 200, "max only shrinks")
    end)

    t.test("map_point and a 2x zoom round trip", function()
        local x, y = g.map_point(500, 250, 1000, 1000, { x = 100, y = 20, w = 200, h = 400 })
        t.eq(x, 200); t.eq(y, 120)
        local content = { x = 0, y = 0, w = 1920, h = 1280 }
        -- zoom 2 on a 3000x2000 camera
        local cx, cy = g.camera_to_canvas(1750, 1000, { x = 1000, y = 500, w = 1500, h = 1000 }, content)
        t.near(cx, 960, 1e-9); t.near(cy, 640, 1e-9)
        -- the same camera point at zoom 1
        cx, cy = g.camera_to_canvas(1750, 1000, { x = 0, y = 0, w = 3000, h = 2000 }, content)
        t.near(cx, 1120, 1e-9); t.near(cy, 640, 1e-9)
    end)
end
