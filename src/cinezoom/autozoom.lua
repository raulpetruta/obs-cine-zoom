-- Auto-zoom state machine (pure: no OBS, no clock of its own).
-- States:
--   out     fully zoomed out
--   in      zoomed in automatically; zooms out again after the idle timeout
--   manual  zoomed in by hotkey; stays until toggled
-- The caller feeds it one input per tick and applies the result {zoom, focus}.
local M = {}

M.DEFAULTS = {
    idle_timeout = 2.5,   -- seconds without activity before zooming out
    min_hold = 0.8,       -- never zoom out sooner than this after zooming in
    zoom_on_typing = false,
    zoom_out_on_fast = false,
    fast_speed = 2.0,     -- camera widths per second that count as "fast"
    typing_click_window = 10, -- typing zooms at the last click if it was this recent
}

---
---@param cfg table|nil Overrides for M.DEFAULTS
---@return table az
function M.new(cfg)
    local az = { cfg = {}, enabled = true }
    M.configure(az, cfg)
    M.reset(az)
    return az
end

function M.configure(az, cfg)
    for k, v in pairs(M.DEFAULTS) do
        az.cfg[k] = v
    end
    for k, v in pairs(cfg or {}) do
        az.cfg[k] = v
    end
    if cfg and cfg.enabled ~= nil then
        M.set_enabled(az, cfg.enabled)
    end
end

function M.reset(az)
    az.state = "out"
    az.since = 0
    az.last_activity = 0
    az.last_click = nil   -- {x, y, t}
    az.pending_focus = nil
    az.prev = nil         -- previous mouse sample for speed
end

---
-- Enable or disable the automatic behaviour. Disabling zooms out of an automatic zoom.
function M.set_enabled(az, on)
    az.enabled = on and true or false
    if not az.enabled and az.state == "in" then
        az.state = "out"
    end
end

---
-- Hotkey: zoom in (at focus = {x, y}) or out, overriding the automatic behaviour
---@param now number
---@param on boolean
---@param focus table|nil {x, y} camera-space position to zoom in on
function M.set_manual(az, now, on, focus)
    if on then
        az.state = "manual"
        az.since = now
        az.last_activity = now
        az.pending_focus = focus
    else
        az.state = "out"
        az.pending_focus = nil
    end
end

local function zoom_in(az, now, x, y)
    az.state = "in"
    az.since = now
    az.last_activity = now
    az.pending_focus = { x = x, y = y }
end

---
-- Advance the machine
---@param az table
---@param now number Seconds (any monotonic clock)
---@param input table {x, y, inside, clicks, left_down, keys, cam_w}
---   x, y     mouse in camera space (nil if unknown)
---   inside   mouse is within the captured area
---   clicks   number of left clicks since the last call
---   left_down  button currently held (drag)
---   keys     number of key presses since the last call
---   cam_w    camera width, to normalise the mouse speed
---@return table result {zoom = boolean, focus = {x, y}|nil}
function M.update(az, now, input)
    local cfg = az.cfg
    local has_pos = type(input.x) == "number" and type(input.y) == "number"
    local inside = has_pos and input.inside

    -- Mouse speed in camera widths per second
    local speed = 0
    if has_pos and az.prev and now > az.prev.t and (input.cam_w or 0) > 0 then
        local dx, dy = input.x - az.prev.x, input.y - az.prev.y
        speed = math.sqrt(dx * dx + dy * dy) / ((now - az.prev.t) * input.cam_w)
    end
    az.prev = has_pos and { x = input.x, y = input.y, t = now } or nil

    if az.enabled then
        -- Clicks outside the captured area are ignored
        if (input.clicks or 0) > 0 and inside then
            az.last_click = { x = input.x, y = input.y, t = now }
            if az.state == "out" then
                zoom_in(az, now, input.x, input.y)
            elseif az.state == "in" then
                az.last_activity = now
                az.pending_focus = { x = input.x, y = input.y } -- refocus
            end
        end

        -- A held button (drag) counts as continuous activity
        if input.left_down and inside and az.state == "in" then
            az.last_activity = now
        end

        if (input.keys or 0) > 0 then
            if az.state == "in" then
                az.last_activity = now
            elseif az.state == "out" and cfg.zoom_on_typing then
                -- The caret position is unknown, so use the last click if it is recent
                local c = az.last_click
                if c and now - c.t <= cfg.typing_click_window then
                    zoom_in(az, now, c.x, c.y)
                elseif inside then
                    zoom_in(az, now, input.x, input.y)
                end
            end
        end

        if az.state == "in" and now - az.since >= cfg.min_hold then
            if now - az.last_activity >= cfg.idle_timeout
                or (cfg.zoom_out_on_fast and speed > cfg.fast_speed) then
                az.state = "out"
                az.pending_focus = nil
            end
        end
    end

    local focus = az.pending_focus
    az.pending_focus = nil
    return { zoom = az.state ~= "out", focus = focus }
end

return M
