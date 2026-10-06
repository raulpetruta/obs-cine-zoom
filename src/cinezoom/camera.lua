-- The virtual camera: springs on the view center and on log(zoom).
-- Animating log(zoom) makes zooming feel even (2x -> 4x takes as long as 1x -> 2x).
local spring = require("cinezoom.spring")
local geometry = require("cinezoom.geometry")

local M = {}

-- Spring stiffness presets (all critically damped)
M.PRESETS = { slow = 60, mellow = 120, quick = 220, rapid = 400 }

---
---@param cam_w number Camera space width (source pixels)
---@param cam_h number Camera space height
---@param k number|nil Spring stiffness
---@return table camera
function M.new(cam_w, cam_h, k)
    k = k or M.PRESETS.mellow
    return {
        w = cam_w,
        h = cam_h,
        cx = spring.new(cam_w / 2, k, 1, 0.05),
        cy = spring.new(cam_h / 2, k, 1, 0.05),
        lz = spring.new(0, k, 1, 1e-4),
    }
end

function M.set_stiffness(cam, k)
    cam.cx.k, cam.cy.k, cam.lz.k = k, k, k
end

---
-- Change the camera space size. Resets the camera to the full view.
function M.set_bounds(cam, w, h)
    cam.w, cam.h = w, h
    M.snap(cam, w / 2, h / 2, 1)
end

function M.set_target(cam, cx, cy, z)
    cam.cx.target = cx
    cam.cy.target = cy
    cam.lz.target = math.log(math.max(z or 1, 1))
end

function M.snap(cam, cx, cy, z)
    spring.snap(cam.cx, cx)
    spring.snap(cam.cy, cy)
    spring.snap(cam.lz, math.log(math.max(z or 1, 1)))
end

function M.step(cam, dt)
    spring.step(cam.cx, dt)
    spring.step(cam.cy, dt)
    spring.step(cam.lz, dt)
    -- Note: a settled spring snaps exactly onto its target, so zooming all the way out
    -- (target log(1) == 0) lands exactly on the full rect.
end

function M.zoom(cam)
    return math.exp(cam.lz.x)
end

---
-- The rectangle (in camera space) the camera currently shows
---@return table rect {x, y, w, h}
function M.rect(cam)
    return geometry.view_rect(cam.cx.x, cam.cy.x, M.zoom(cam), cam.w, cam.h)
end

function M.is_settled(cam)
    return spring.is_settled(cam.cx) and spring.is_settled(cam.cy) and spring.is_settled(cam.lz)
end

return M
