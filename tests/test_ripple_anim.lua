local anim = require("cinezoom.effects.ripple_anim")

return function(t)
    t.test("ripple scale grows from the start scale to 1", function()
        local cfg = { opacity = 0.85 }
        local prev = -1
        for i = 0, 100 do
            local s = anim.sample(i / 100 * 0.5, 0.5, cfg)
            t.truthy(s.scale >= prev - 1e-12, "scale never decreases")
            prev = s.scale
        end
        t.near(anim.sample(0, 0.5, cfg).scale, anim.START_SCALE, 1e-12)
        t.near(anim.sample(0.5, 0.5, cfg).scale, 1, 1e-12)
    end)

    t.test("ripple opacity starts at the maximum and fades to 0", function()
        local cfg = { opacity = 0.85 }
        local prev = 2
        for i = 0, 100 do
            local s = anim.sample(i / 100 * 0.5, 0.5, cfg)
            t.truthy(s.opacity <= prev + 1e-12, "opacity never increases")
            prev = s.opacity
        end
        t.near(anim.sample(0, 0.5, cfg).opacity, 0.85, 1e-12)
        t.near(anim.sample(0.5, 0.5, cfg).opacity, 0, 1e-12)
    end)

    t.test("ripple done flag and zero duration", function()
        t.eq(anim.sample(0.49, 0.5, {}).done, false)
        t.eq(anim.sample(0.5, 0.5, {}).done, true)
        local s = anim.sample(0, 0, { opacity = 1 })
        t.truthy(s.scale == s.scale and s.opacity == s.opacity, "no NaN")
        t.eq(s.done, true)
        t.eq(anim.sample(-1, 0.5, {}).scale, anim.START_SCALE)
    end)
end
