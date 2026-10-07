-- Studio images: gradient, rounded mask and shadow (pure pixel math), and their PNG encoding.
local raster = require("cinezoom.assets.raster")
local png = require("cinezoom.assets.png")
local layout = require("cinezoom.studio.layout")

local function px(rgba, w, x, y)
    local i = (y * w + x) * 4
    return rgba:byte(i + 1, i + 4)
end

return function(t)
    t.test("gradient: size, angle 0 runs left to right, angle 90 top to bottom", function()
        local c1, c2 = 0xFF0000FF, 0xFFFF0000 -- red to blue (0xAABBGGRR)
        local w, h = 64, 36
        local img = raster.gradient_rgba(w, h, c1, c2, 0)
        t.eq(#img, w * h * 4)
        local r, _, b, a = px(img, w, 0, 10)
        t.truthy(r >= 250 and b <= 5, "left column is c1")
        t.eq(a, 255)
        r, _, b = px(img, w, w - 1, 10)
        t.truthy(r <= 5 and b >= 250, "right column is c2")
        local mr = px(img, w, w / 2, 0)
        t.near(mr, 127, 6, "middle is halfway")
        t.eq(({ px(img, w, 5, 0) })[1], ({ px(img, w, 5, h - 1) })[1], "angle 0 is constant down a column (within the dither)")

        local down = raster.gradient_rgba(w, h, c1, c2, 90)
        local tr, _, tb = px(down, w, 10, 0)
        t.truthy(tr >= 245 and tb <= 10, "top row is c1")
        tr, _, tb = px(down, w, 10, h - 1)
        t.truthy(tr <= 10 and tb >= 245, "bottom row is c2")
        local l = px(down, w, 0, 10)
        local rr = px(down, w, w - 1, 10)
        t.near(l, rr, 1, "angle 90 does not change along a row")
    end)

    t.test("rounded mask: transparent outside the corner, opaque inside, RGB equals alpha", function()
        local w, h = 100, 60
        local rect = { x = 10, y = 10, w = 80, h = 40 }
        local img = raster.rounded_mask_rgba(w, h, rect, 12)
        t.eq(#img, w * h * 4)
        local _, _, _, a = px(img, w, 10, 10) -- the very corner pixel of the rect lies outside the arc
        t.eq(a, 0, "outside the corner")
        _, _, _, a = px(img, w, 50, 30)
        t.eq(a, 255, "centre")
        _, _, _, a = px(img, w, 50, 10) -- top edge midpoint, first row inside
        t.eq(a, 255, "edge midpoint")
        _, _, _, a = px(img, w, 2, 2)
        t.eq(a, 0, "outside the rect")
        local bad = 0
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local r, g, b, al = px(img, w, x, y)
                if r ~= al or g ~= al or b ~= al then bad = bad + 1 end
            end
        end
        t.eq(bad, 0, "pixels where RGB differs from alpha")
    end)

    t.test("rounded mask with radius 0 keeps the corner pixel opaque", function()
        local img = raster.rounded_mask_rgba(100, 60, { x = 10, y = 10, w = 80, h = 40 }, 0)
        local _, _, _, a = px(img, 100, 10, 10)
        t.eq(a, 255)
        _, _, _, a = px(img, 100, 9, 9)
        t.eq(a, 0)
    end)

    t.test("shadow: transparent edges, soft falloff, symmetric", function()
        local target = { x = 0, y = 0, w = 800, h = 400 }
        local spec = layout.shadow_spec(target, 40, 18)
        local img = raster.shadow_rgba(spec, 0.45)
        local w, h = spec.w, spec.h
        t.eq(#img, w * h * 4)
        local function alpha(x, y) local _, _, _, a = px(img, w, x, y); return a end
        for _, p in ipairs({ { 0, 0 }, { w - 1, 0 }, { 0, h - 1 }, { w - 1, h - 1 }, { 0, math.floor(h / 2) }, { math.floor(w / 2), 0 } }) do
            t.eq(alpha(p[1], p[2]), 0, "edge " .. p[1] .. "," .. p[2])
        end
        local cx, cy = math.floor(w / 2), math.floor(h / 2)
        t.near(alpha(cx, cy), 114.75, 1, "centre is opacity * 255")
        -- no colour channel but black
        local r, g, b = px(img, w, cx, cy)
        t.eq(r + g + b, 0)
        -- monotonic non-increasing from the centre outward
        local prev = alpha(cx, cy)
        for x = cx, w - 1 do
            local a = alpha(x, cy)
            t.truthy(a <= prev, "row not monotonic at " .. x)
            prev = a
        end
        prev = alpha(cx, cy)
        for y = cy, h - 1 do
            local a = alpha(cx, y)
            t.truthy(a <= prev, "column not monotonic at " .. y)
            prev = a
        end
        for x = 0, math.floor(w / 2) do
            t.near(alpha(x, cy), alpha(w - 1 - x, cy), 1, "left/right symmetry at " .. x)
        end
        -- a custom colour
        local red = raster.shadow_rgba(spec, 1, { 255, 0, 0 })
        local rr, rg, rb, ra = px(red, w, cx, cy)
        t.eq(rr, 255); t.eq(rg, 0); t.eq(rb, 0); t.eq(ra, 255)
    end)

    t.test("png.encode writes the size of the studio images into the IHDR", function()
        local rgba = raster.rounded_mask_rgba(96, 54, { x = 0, y = 0, w = 96, h = 54 }, 5)
        local data = png.encode(96, 54, rgba)
        t.eq(data:sub(2, 4), "PNG")
        local function be(i) local a, b, c, d = data:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
        t.eq(be(17), 96)
        t.eq(be(21), 54)
    end)
end
