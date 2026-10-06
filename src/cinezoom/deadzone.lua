-- Follow behaviour: the camera stays put while the mouse is inside a rectangle around
-- the view center, and only moves when the mouse pushes against the edge of that rectangle.
local M = {}

---
-- Returns the new target center for the camera
---@param tx number Current target center x
---@param ty number Current target center y
---@param mx number Mouse x (camera space)
---@param my number Mouse y (camera space)
---@param view_w number Width of the zoomed view
---@param view_h number Height of the zoomed view
---@param frac number Deadzone size as a fraction (0-1) of half the view
---@return number x, number y
function M.apply(tx, ty, mx, my, view_w, view_h, frac)
    local lx = frac * view_w * 0.5
    local ly = frac * view_h * 0.5

    local dx = mx - tx
    if dx > lx then
        tx = mx - lx
    elseif dx < -lx then
        tx = mx + lx
    end

    local dy = my - ty
    if dy > ly then
        ty = my - ly
    elseif dy < -ly then
        ty = my + ly
    end

    return tx, ty
end

return M
