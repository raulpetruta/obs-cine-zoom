-- Critically damped spring, integrated with semi-implicit Euler in small fixed substeps
-- so the motion does not depend on the frame rate.
local M = {}

local MAX_DT = 0.25       -- never integrate more than this per call (tab-outs, breakpoints)
local MAX_STEP = 1 / 240  -- substep size

---
---@param x number Initial value
---@param k number Stiffness
---@param zeta number|nil Damping ratio, 1 = critical
---@param eps number|nil Snap distance
---@return table spring
function M.new(x, k, zeta, eps)
    return { x = x, v = 0, target = x, k = k or 120, zeta = zeta or 1, eps = eps or 0.01 }
end

function M.is_settled(s)
    return math.abs(s.target - s.x) < s.eps and math.abs(s.v) < s.eps
end

---
-- Advance the spring by dt seconds and return the new value
---@return number
function M.step(s, dt)
    if not (dt > 0) then -- also rejects NaN
        return s.x
    end
    if dt > MAX_DT then
        dt = MAX_DT
    end

    local n = math.ceil(dt / MAX_STEP)
    local h = dt / n
    local c = 2 * s.zeta * math.sqrt(s.k)
    for _ = 1, n do
        local a = s.k * (s.target - s.x) - c * s.v
        s.v = s.v + a * h
        s.x = s.x + s.v * h
    end

    if M.is_settled(s) then
        s.x = s.target
        s.v = 0
    end
    return s.x
end

---
-- Jump to a value without animating
function M.snap(s, x)
    s.x = x
    s.target = x
    s.v = 0
end

return M
