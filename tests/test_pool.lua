local pool = require("cinezoom.effects.pool")

return function(t)
    t.test("pool hands out free slots, then steals the oldest", function()
        local p = pool.new(3)
        local a, b, c = p:acquire(1), p:acquire(2), p:acquire(3)
        t.truthy(a ~= b and b ~= c and a ~= c)
        t.eq(p:acquire(4), a, "oldest taken over")
        t.eq(p:acquire(5), b)
        t.eq(a.t0, 4)
    end)

    t.test("pool release and iteration", function()
        local p = pool.new(3)
        local a, b = p:acquire(0), p:acquire(0)
        local n = 0
        p:each_active(function() n = n + 1 end)
        t.eq(n, 2)
        p:release(a)
        n = 0
        p:each_active(function(s) n = n + 1; t.eq(s, b) end)
        t.eq(n, 1)
        t.eq(p:acquire(1), a, "released slot is reused first")
        t.truthy(p:any_active())
        p:release(a); p:release(b)
        t.eq(p:any_active(), false)
    end)
end
