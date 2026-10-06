-- Ripple animation curve (pure): the ring grows with an ease-out and fades over time.
local M = {}

M.START_SCALE = 0.25

local function smoothstep(a, b, x)
    local u = math.max(0, math.min(1, (x - a) / (b - a)))
    return u * u * (3 - 2 * u)
end

---
-- State of a ripple at `age` seconds
---@param age number Seconds since the click
---@param duration number Total seconds
---@param cfg table|nil {opacity = peak opacity 0..1 (default 1)}
---@return table {scale, opacity, done}
function M.sample(age, duration, cfg)
    local max_op = cfg and cfg.opacity or 1
    local u = math.max(0, math.min(1, age / math.max(duration, 1e-3)))
    local s0 = M.START_SCALE
    return {
        scale = s0 + (1 - s0) * (1 - (1 - u) ^ 3),
        opacity = max_op * (1 - smoothstep(0.3, 1, u)),
        done = age >= duration,
    }
end

return M
