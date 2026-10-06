local az_mod = require("cinezoom.autozoom")

-- Drive the machine with a script of {time, input} steps; returns the result of the last step
local function run(az, steps)
    local res
    for _, s in ipairs(steps) do
        local input = { x = 500, y = 400, inside = true, clicks = 0, keys = 0, left_down = false, cam_w = 1000 }
        for k, v in pairs(s[2] or {}) do input[k] = v end
        res = az_mod.update(az, s[1], input)
    end
    return res
end

return function(t)
    t.test("click zooms in at the click position", function()
        local az = az_mod.new()
        local r = run(az, { { 0 }, { 0.1, { clicks = 1, x = 300, y = 200 } } })
        t.eq(r.zoom, true)
        t.eq(r.focus.x, 300); t.eq(r.focus.y, 200)
        -- the focus is only reported once
        r = run(az, { { 0.2 } })
        t.eq(r.focus, nil)
        t.eq(r.zoom, true)
    end)

    t.test("a second click refocuses while zoomed in", function()
        local az = az_mod.new()
        run(az, { { 0.1, { clicks = 1 } } })
        local r = run(az, { { 1.0, { clicks = 1, x = 800, y = 700 } } })
        t.eq(r.focus.x, 800)
    end)

    t.test("zooms out after the idle timeout, not before", function()
        local az = az_mod.new({ idle_timeout = 2.5, min_hold = 0.8 })
        run(az, { { 0, { clicks = 1 } } })
        t.eq(run(az, { { 2.4 } }).zoom, true)
        t.eq(run(az, { { 2.6 } }).zoom, false)
    end)

    t.test("minimum hold delays a short idle timeout", function()
        local az = az_mod.new({ idle_timeout = 0.2, min_hold = 0.8 })
        run(az, { { 0, { clicks = 1 } } })
        t.eq(run(az, { { 0.5 } }).zoom, true)
        t.eq(run(az, { { 0.85 } }).zoom, false)
    end)

    t.test("a held button (drag) keeps the zoom alive", function()
        local az = az_mod.new({ idle_timeout = 1, min_hold = 0.5 })
        run(az, { { 0, { clicks = 1 } } })
        for i = 1, 40 do
            run(az, { { i * 0.1, { left_down = true } } })
        end
        t.eq(run(az, { { 4.1, { left_down = true } } }).zoom, true)
        t.eq(run(az, { { 5.5 } }).zoom, false)
    end)

    t.test("key presses keep the zoom alive", function()
        local az = az_mod.new({ idle_timeout = 1, min_hold = 0.5 })
        run(az, { { 0, { clicks = 1 } } })
        for i = 1, 20 do
            run(az, { { i * 0.5, { keys = 1 } } })
        end
        t.eq(run(az, { { 10.2 } }).zoom, true)
        t.eq(run(az, { { 11.5 } }).zoom, false)
    end)

    t.test("clicks outside the captured area are ignored", function()
        local az = az_mod.new()
        local r = run(az, { { 0, { clicks = 1, inside = false } } })
        t.eq(r.zoom, false)
    end)

    t.test("typing zooms in only when enabled", function()
        local az = az_mod.new({ zoom_on_typing = false })
        t.eq(run(az, { { 0, { keys = 1 } } }).zoom, false)

        az = az_mod.new({ zoom_on_typing = true })
        local r = run(az, { { 0, { keys = 1, x = 640, y = 360 } } })
        t.eq(r.zoom, true)
        t.eq(r.focus.x, 640) -- no recent click: zoom at the mouse
    end)

    t.test("typing zooms at the last click if it was within 10 s", function()
        local az = az_mod.new({ zoom_on_typing = true, idle_timeout = 1, min_hold = 0.1 })
        run(az, { { 0, { clicks = 1, x = 111, y = 222 } } })
        t.eq(run(az, { { 2 } }).zoom, false) -- idled out
        local r = run(az, { { 5, { keys = 1, x = 900, y = 900 } } })
        t.eq(r.zoom, true)
        t.eq(r.focus.x, 111); t.eq(r.focus.y, 222)
        -- a click older than 10 s is ignored
        run(az, { { 7 } })
        r = run(az, { { 20, { keys = 1, x = 900, y = 900 } } })
        t.eq(r.focus.x, 900)
    end)

    t.test("fast mouse movement zooms out when enabled", function()
        local az = az_mod.new({ zoom_out_on_fast = true, fast_speed = 2, min_hold = 0.2, idle_timeout = 100 })
        run(az, { { 0, { clicks = 1, x = 100 } } })
        t.eq(run(az, { { 0.5, { x = 110 } } }).zoom, true)
        -- 800 px in 0.1 s on a 1000 px wide camera = 8 widths/s
        t.eq(run(az, { { 0.6, { x = 910 } } }).zoom, false)
    end)

    t.test("manual zoom ignores the idle timeout and click refocus", function()
        local az = az_mod.new({ idle_timeout = 1, min_hold = 0.1 })
        az_mod.set_manual(az, 0, true, { x = 50, y = 60 })
        local r = run(az, { { 0.1 } })
        t.eq(r.zoom, true); t.eq(r.focus.x, 50)
        t.eq(run(az, { { 30 } }).zoom, true)
        r = run(az, { { 31, { clicks = 1, x = 900 } } })
        t.eq(r.zoom, true); t.eq(r.focus, nil)
        az_mod.set_manual(az, 32, false)
        t.eq(run(az, { { 32.1 } }).zoom, false)
    end)

    t.test("manual zoom out overrides an automatic zoom", function()
        local az = az_mod.new()
        run(az, { { 0, { clicks = 1 } } })
        az_mod.set_manual(az, 0.5, false)
        t.eq(run(az, { { 0.6 } }).zoom, false)
    end)

    t.test("disabling the machine stops auto zoom but not manual zoom", function()
        local az = az_mod.new()
        az_mod.set_enabled(az, false)
        t.eq(run(az, { { 0, { clicks = 1 } } }).zoom, false)
        az_mod.set_manual(az, 1, true)
        t.eq(run(az, { { 1.1, { clicks = 1 } } }).zoom, true)
    end)

    t.test("disabling during an automatic zoom zooms out", function()
        local az = az_mod.new()
        run(az, { { 0, { clicks = 1 } } })
        az_mod.set_enabled(az, false)
        t.eq(run(az, { { 0.1 } }).zoom, false)
    end)

    t.test("unknown mouse position never crashes", function()
        local az = az_mod.new()
        local r = run(az, { { 0, { x = false, clicks = 1, keys = 1 } } })
        t.eq(r.zoom, false)
    end)
end
