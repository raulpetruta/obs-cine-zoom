-- Capture-source knowledge: which source ids we can follow the mouse on, and how to find
-- which display (position + size in MOUSE units) a given capture source is showing.
local obs = obslua
local log = require("cinezoom.log")
local geometry = require("cinezoom.geometry")

local M = {}

-- Dropdown value meaning "no zoom source selected"
M.NONE = "cinezoom-none"

-- Capture source ids per platform (ffi.os names).
--   prop/ptype: the source property that picks the display, used for the name lookup
--   no_mouse:   the mouse position is not visible to us, so only a manual override works
local KINDS = {
    OSX = {
        { id = "screen_capture", prop = "display_uuid", ptype = "string" },
        { id = "display_capture", prop = "display", ptype = "int" },
    },
    Windows = {
        { id = "monitor_capture", prop = "monitor_id", ptype = "string" },
    },
    Linux = {
        { id = "xshm_input", prop = "screen", ptype = "int" },
        { id = "pipewire-desktop-capture-source", no_mouse = true },
    },
}

---
-- Description of a capture source id, or nil if it is not a capture source on this OS
---@param id string
---@param os_name string
---@return table|nil
function M.capture_info(id, os_name)
    for _, kind in ipairs(KINDS[os_name] or {}) do
        if kind.id == id then
            return kind
        end
    end
    return nil
end

---
-- True if the source id is a display capture source on this OS.
-- (The original script returned the opposite when "allow all sources" was off.)
---@return boolean
function M.is_capture(id, os_name)
    return M.capture_info(id, os_name) ~= nil
end

---
-- Fill the Zoom Source dropdown
---@param list any obs property list
---@param os_name string
---@param allow_all boolean List every source, not only captures
function M.populate(list, os_name, allow_all)
    obs.obs_property_list_clear(list)
    obs.obs_property_list_add_string(list, "<None>", M.NONE)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            if allow_all or M.is_capture(obs.obs_source_get_id(source), os_name) then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end
end

---
-- Find the list-item name of the display a capture source points at.
-- Returns nil if the source has no such property or the value is not in the list.
local function find_display_name(source, kind, settings)
    if not kind.prop then
        return nil
    end
    local props = obs.obs_source_properties(source)
    if props == nil then
        return nil
    end

    local found = nil
    local prop = obs.obs_properties_get(props, kind.prop)
    if prop ~= nil then
        local to_match
        if kind.ptype == "string" then
            to_match = obs.obs_data_get_string(settings, kind.prop)
        else
            to_match = obs.obs_data_get_int(settings, kind.prop)
        end

        -- Items are 0 .. count-1 (the original looped to count and read one past the end)
        for i = 0, obs.obs_property_list_item_count(prop) - 1 do
            local value
            if kind.ptype == "string" then
                value = obs.obs_property_list_item_string(prop, i)
            else
                value = obs.obs_property_list_item_int(prop, i)
            end
            if value == to_match then
                found = obs.obs_property_list_item_name(prop, i)
                break
            end
        end
    end

    obs.obs_properties_destroy(props)
    return found
end

local function copy_display(d, method)
    return {
        x = d.x, y = d.y, w = d.w, h = d.h,
        px_w = d.px_w or d.w, px_h = d.px_h or d.h,
        uuid = d.uuid, main = d.main, id = d.id,
        scale_x = d.scale_x, scale_y = d.scale_y,
        method = method,
    }
end

---
-- Work out which display a source is capturing.
-- Order: manual override, macOS ScreenCaptureKit UUID, legacy macOS index,
-- display-name parse. Logs a WARN (always visible) if nothing works.
---@param source any The OBS source (may be nil)
---@param ctx table {os, backend, override = {enabled,x,y,w,h,sx,sy}}
---@return table|nil display {x,y,w,h,px_w,px_h,method,...}
---@return string note The method used, or the reason it failed
function M.resolve_display(source, ctx)
    local ov = ctx.override
    if ov and ov.enabled then
        if ov.w > 0 and ov.h > 0 then
            return {
                x = ov.x, y = ov.y, w = ov.w, h = ov.h, px_w = ov.w, px_h = ov.h,
                scale_x = ov.sx > 0 and ov.sx or nil,
                scale_y = ov.sy > 0 and ov.sy or nil,
                method = "manual override",
            }, "manual override"
        end
        log.warn("Manual source position is on but Width/Height are 0, ignoring it.")
    end

    if source == nil then
        return nil, "no zoom source"
    end

    local id = obs.obs_source_get_id(source)
    local kind = M.capture_info(id, ctx.os)
    if not kind then
        log.warn("Zoom source '%s' is not a display capture (%s). " ..
            "Enable 'Manual source position' and enter its size and position.", obs.obs_source_get_name(source), tostring(id))
        return nil, "not a capture source"
    end
    if kind.no_mouse then
        log.warn("%s sources do not expose the mouse position. Use 'Manual source position' " ..
            "and the remote mouse listener.", id)
        return nil, "no mouse access for this source type"
    end

    local displays = nil
    if ctx.backend and ctx.backend.displays then
        local okd, list = pcall(ctx.backend.displays)
        displays = okd and list or nil
    end

    local settings = obs.obs_source_get_settings(source)
    local result, note

    if settings ~= nil and displays ~= nil and ctx.os == "OSX" then
        if id == "screen_capture" then
            -- ScreenCaptureKit: type 0 = display, 1 = window, 2 = application
            if obs.obs_data_get_int(settings, "type") ~= 0 then
                obs.obs_data_release(settings)
                log.warn("Window/application capture has no fixed display. " ..
                    "Enable 'Manual source position' and enter the display's position and size.")
                return nil, "window/application capture needs a manual override"
            end
            local uuid = obs.obs_data_get_string(settings, "display_uuid")
            for _, d in ipairs(displays) do
                if (uuid == "" and d.main) or geometry.uuid_eq(uuid, d.uuid) then
                    result, note = d, uuid == "" and "main display (no uuid set)" or "display uuid"
                    break
                end
            end
        else
            -- Legacy display_capture: uuid if the source has one, otherwise the display index
            local uuid = obs.obs_data_get_string(settings, "display_uuid")
            if uuid ~= "" then
                for _, d in ipairs(displays) do
                    if geometry.uuid_eq(uuid, d.uuid) then
                        result, note = d, "display uuid"
                        break
                    end
                end
            end
            if not result then
                result = displays[obs.obs_data_get_int(settings, "display") + 1]
                note = "display index"
            end
        end
    end

    if result then
        obs.obs_data_release(settings)
        return copy_display(result, note), note
    end

    -- Last resort: parse "WxH @ x,y" out of the display's name in the property list
    if settings ~= nil then
        local name = find_display_name(source, kind, settings)
        obs.obs_data_release(settings)
        local rect = name and geometry.parse_display_name(name)
        if rect then
            if ctx.os == "OSX" then
                local main_h
                for _, d in ipairs(displays or {}) do
                    if d.main then main_h = d.h end
                end
                if main_h then
                    rect = geometry.cocoa_rect_to_cg(rect, main_h)
                end
            end
            rect.method = "display name"
            return copy_display(rect, "display name"), "display name"
        end
    end

    log.warn("Could not work out which display '%s' captures, so mouse following is disabled. " ..
        "Run Diagnose, or enable 'Manual source position'.", obs.obs_source_get_name(source))
    return nil, "no display match"
end

return M
