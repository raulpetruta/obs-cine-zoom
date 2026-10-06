local spring = require("cinezoom.spring")
local camera = require("cinezoom.camera")
local deadzone = require("cinezoom.deadzone")

local function run(k, fps, seconds, dist)
    local s = spring.new(0, k, 1, 0.01)
    s.target = dist
    local max = 0
    for _ = 1, math.floor(seconds * fps) do
        spring.step(s, 1 / fps)
        if s.x > max then max = s.x end
    end
    return s, max
end

return function(t)
    t.test("converges to the target", function()
        local s = run(120, 60, 3, 1000)
        t.eq(s.x, 1000)
    end)

    t.test("does not overshoot (critically damped)", function()
        for _, k in ipairs({ 60, 120, 220, 400 }) do
            local _, max = run(k, 60, 3, 1000)
            t.truthy(max <= 1000 + 1e-6, "overshoot at k=" .. k .. ": " .. max)
        end
    end)

    t.test("frame-rate independent (30 vs 144 fps within 1 px)", function()
        for _, k in ipairs({ 60, 120, 400 }) do
            local a, b = spring.new(0, k), spring.new(0, k)
            a.target, b.target = 1000, 1000
            -- sample at t = 0.5 s (15 frames at 30 fps, 72 frames at 144 fps)
            for _ = 1, 15 do spring.step(a, 1 / 30) end
            for _ = 1, 72 do spring.step(b, 1 / 144) end
            t.near(a.x, b.x, 1, "k=" .. k)
        end
    end)

    t.test("no NaN for dt = 0, negative, NaN, huge", function()
        local s = spring.new(5, 120)
        s.target = 50
        for _, dt in ipairs({ 0, -1, 0 / 0, 5, 1e9, math.huge }) do
            spring.step(s, dt)
            t.truthy(s.x == s.x and s.v == s.v, "NaN after dt=" .. tostring(dt))
        end
    end)

    t.test("dt is clamped to 0.25 s", function()
        local a, b = spring.new(0, 30), spring.new(0, 30)
        a.target, b.target = 1000, 1000
        spring.step(a, 5)
        spring.step(b, 0.25)
        t.eq(a.x, b.x)
    end)

    t.test("camera zoom out returns EXACTLY to the full rect", function()
        local cam = camera.new(1920, 1080, 120)
        camera.set_target(cam, 1400, 300, 3)
        for _ = 1, 600 do camera.step(cam, 1 / 60) end
        local r = camera.rect(cam)
        t.near(r.w, 640, 0.5)
        camera.set_target(cam, 1400, 300, 1)
        for _ = 1, 900 do camera.step(cam, 1 / 60) end
        r = camera.rect(cam)
        t.eq(r.x, 0); t.eq(r.y, 0); t.eq(r.w, 1920); t.eq(r.h, 1080)
        t.truthy(camera.is_settled(cam))
    end)

    t.test("camera zoom is perceptually even (log space)", function()
        local cam = camera.new(1000, 1000, 120)
        camera.set_target(cam, 500, 500, 4)
        for _ = 1, 600 do camera.step(cam, 1 / 60) end
        t.near(camera.zoom(cam), 4, 1e-3)
    end)

    t.test("camera presets exist", function()
        t.eq(camera.PRESETS.slow, 60); t.eq(camera.PRESETS.mellow, 120)
        t.eq(camera.PRESETS.quick, 220); t.eq(camera.PRESETS.rapid, 400)
    end)

    t.test("deadzone holds the target while the mouse is inside", function()
        local x, y = deadzone.apply(500, 400, 560, 380, 400, 300, 0.5)
        t.eq(x, 500); t.eq(y, 400)
    end)

    t.test("deadzone drags the target when the mouse pushes the edge", function()
        -- half view 200, frac 0.5 -> zone half-width 100
        local x, y = deadzone.apply(500, 400, 700, 400, 400, 300, 0.5)
        t.eq(x, 600); t.eq(y, 400)
        x = deadzone.apply(500, 400, 300, 400, 400, 300, 0.5)
        t.eq(x, 400)
    end)

    t.test("deadzone of 0 follows the mouse exactly", function()
        local x, y = deadzone.apply(0, 0, 123, 456, 400, 300, 0)
        t.eq(x, 123); t.eq(y, 456)
    end)
end
