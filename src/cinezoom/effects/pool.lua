-- Fixed-size slot pool (pure). A slot is a table {index, active, t0, seq}; the owner attaches its
-- own fields to it. Acquiring when every slot is busy takes over the oldest one.
local M = {}

local Pool = {}
Pool.__index = Pool

---
---@param n number Number of slots
---@return table pool
function M.new(n)
    local pool = setmetatable({ slots = {}, counter = 0 }, Pool)
    for i = 1, n do
        pool.slots[i] = { index = i, active = false, t0 = 0, seq = 0 }
    end
    return pool
end

---
-- A free slot, or the oldest active one when none is free
---@param now number
---@return table slot
function Pool:acquire(now)
    local pick = nil
    for _, s in ipairs(self.slots) do
        if not s.active then
            pick = s
            break
        end
        if pick == nil or s.seq < pick.seq then
            pick = s
        end
    end
    self.counter = self.counter + 1
    pick.active, pick.t0, pick.seq = true, now, self.counter
    return pick
end

function Pool:release(slot)
    slot.active = false
end

---
-- Call fn(slot) for every active slot
function Pool:each_active(fn)
    for _, s in ipairs(self.slots) do
        if s.active then
            fn(s)
        end
    end
end

function Pool:any_active()
    for _, s in ipairs(self.slots) do
        if s.active then
            return true
        end
    end
    return false
end

return M
