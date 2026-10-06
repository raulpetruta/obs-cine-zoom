-- Click ripple: a ring image that grows and fades where you clicked.
-- Layout: one private overlay scene holds a pool of image slots (private image_source with a private
-- color filter for the fade). The overlay scene is added ONCE to the scene that holds the capture
-- item, directly above it, as a locked item at (0,0) with scale 1. Everything is private, so a saved
-- scene collection never contains our sources, and the item is removed on scene change, collection
-- change and unload.
local obs = obslua
local log = require("cinezoom.log")
local geometry = require("cinezoom.geometry")
local anim = require("cinezoom.effects.ripple_anim")
local pool_mod = require("cinezoom.effects.pool")

local M = {}

M.OVERLAY_NAME = "OBSCineZoom click effects"
M.SLOTS = 4

local get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local Ripple = {}
Ripple.__index = Ripple

---
---@return table ripple controller (creates nothing until configure)
function M.new()
    return setmetatable({
        overlay = nil,
        pool = nil,
        host = nil,       -- {item, id, name, grouped, order}: our item in the capture's scene
        cfg = nil,
        path = nil,
        tex_w = 0,
        fade = nil,       -- "v2", "v1" or "none" once decided
        blocked = false,  -- rotated capture: no ripple until the next attach
        last = nil,       -- last placement, for Diagnose
    }, Ripple)
end

local function bounds_constants()
    return {
        NONE = obs.OBS_BOUNDS_NONE, STRETCH = obs.OBS_BOUNDS_STRETCH, SCALE_INNER = obs.OBS_BOUNDS_SCALE_INNER,
        SCALE_OUTER = obs.OBS_BOUNDS_SCALE_OUTER, SCALE_TO_WIDTH = obs.OBS_BOUNDS_SCALE_TO_WIDTH,
        SCALE_TO_HEIGHT = obs.OBS_BOUNDS_SCALE_TO_HEIGHT, MAX_ONLY = obs.OBS_BOUNDS_MAX_ONLY,
    }
end

local function read_info(item)
    local info = obs.obs_transform_info()
    get_info(item, info)
    return info
end

local function scene_name(scene)
    return obs.obs_source_get_name(obs.obs_scene_get_source(scene))
end

-- Bottom-to-top index (0 = bottom) of an item in a scene, compared by id
local function index_of(scene, item)
    local want = obs.obs_sceneitem_get_id(item)
    local found = nil
    local list = obs.obs_scene_enum_items(scene)
    if list then
        for i, it in ipairs(list) do
            if obs.obs_sceneitem_get_id(it) == want then
                found = i - 1
                break
            end
        end
        obs.sceneitem_list_release(list)
    end
    return found
end

local function image_settings(path)
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "file", path)
    obs.obs_data_set_bool(s, "unload", false)
    return s
end

-- Create the opacity filter of a slot: color_filter_v2 (opacity 0..1), else color_filter (0..100)
local function add_fade(self, slot)
    local tries = { { id = "color_filter_v2", mode = "v2" }, { id = "color_filter", mode = "v1" } }
    for _, t in ipairs(tries) do
        if self.fade == nil or self.fade == t.mode then
            local fdata = obs.obs_data_create()
            if t.mode == "v2" then
                obs.obs_data_set_double(fdata, "opacity", 0.0)
            else
                obs.obs_data_set_int(fdata, "opacity", 0)
            end
            local f = obs.obs_source_create_private(t.id, "cz-ripple-opacity", fdata)
            if f ~= nil then
                obs.obs_source_filter_add(slot.img, f)
                slot.filter, slot.fdata, slot.op = f, fdata, nil
                self.fade = t.mode
                return
            end
            obs.obs_data_release(fdata)
        end
    end
    if self.fade == nil then
        self.fade = "none"
        log.warn("Click ripple: no opacity filter is available, the ripple will not fade out smoothly.")
    end
end

local function create_slot(self, slot, path)
    local s = image_settings(path)
    local img = obs.obs_source_create_private("image_source", "OBSCineZoom ripple " .. slot.index, s)
    obs.obs_data_release(s)
    if img == nil then
        error("could not create the image source", 0)
    end
    slot.img = img
    add_fade(self, slot)
    local item = obs.obs_scene_add(self.overlay, img)
    if item == nil then
        error("could not add the image to the overlay scene", 0)
    end
    obs.obs_sceneitem_addref(item)
    slot.item = item
    obs.obs_sceneitem_set_visible(item, false)
end

-- Size of the ring image in pixels (a custom image is measured, 0 if OBS does not know yet)
local function measure(self)
    local slot = self.pool and self.pool.slots[1]
    if slot and slot.img then
        local w = obs.obs_source_get_width(slot.img)
        if w and w > 0 then
            return w
        end
    end
    return 0
end

---
-- Create the overlay and slots on first use, or apply a changed image and settings.
---@param rc table ripple settings {size, duration, opacity (0..1), zoom_scale}
---@param path string Ring image
---@param tex_w number|nil Image width in pixels (nil: ask OBS)
---@return boolean ok
function Ripple:configure(rc, path, tex_w)
    self.cfg = rc
    local ok, err = pcall(function()
        if self.overlay == nil then
            self.B = bounds_constants()
            self.overlay = obs.obs_scene_create_private(M.OVERLAY_NAME)
            if self.overlay == nil then
                error("could not create the overlay scene", 0)
            end
            self.pool = pool_mod.new(M.SLOTS)
            self.fade = nil
            for _, slot in ipairs(self.pool.slots) do
                create_slot(self, slot, path)
            end
            self.path = path
        elseif path ~= self.path then
            for _, slot in ipairs(self.pool.slots) do
                local s = image_settings(path)
                obs.obs_source_update(slot.img, s)
                obs.obs_data_release(s)
            end
            self.path = path
        end
        self.tex_w = tex_w or measure(self)
    end)
    if not ok then
        log.warn("Click ripple could not be set up: %s", tostring(err))
        self:destroy()
        return false
    end
    return true
end

local function item_alive(host)
    local scene = obs.obs_sceneitem_get_scene(host.item)
    return scene ~= nil and obs.obs_scene_find_sceneitem_by_id(scene, host.id) ~= nil
end

-- The scene that will hold the overlay, the item to stack it above, and whether the capture is in a group
local function host_for(si)
    local scene = obs.obs_sceneitem_get_scene(si.item)
    if scene == nil then
        return nil
    end
    if obs.obs_scene_is_group(scene) then
        if si.group_item == nil then
            return nil
        end
        return obs.obs_sceneitem_get_scene(si.group_item), si.group_item, true
    end
    return scene, si.item, false
end

---
-- Make sure the overlay item sits directly above the capture item (re-created if it went missing).
---@param si table scene item controller
---@return boolean ready
function Ripple:ensure_host(si)
    if self.overlay == nil or si.item == nil or self.blocked then
        return false
    end
    local scene, anchor, grouped = host_for(si)
    if scene == nil then
        log.debug("Click ripple: the scene of the capture item is unknown")
        return false
    end

    -- Rotation and flips are not handled by the ripple math
    for _, it in ipairs(grouped and { si.item, si.group_item } or { si.item }) do
        local info = read_info(it)
        if info.rot ~= 0 or info.scale.x < 0 or info.scale.y < 0 then
            self.blocked = true
            log.warn("Click ripple is off for this capture: it is rotated or flipped, which the ripple cannot follow.")
            return false
        end
    end

    local name = scene_name(scene)
    local host = self.host
    if host ~= nil then
        if host.name == name and host.grouped == grouped and item_alive(host) then
            return true
        end
        self:detach_host()
    end

    local item = obs.obs_scene_add(scene, obs.obs_scene_get_source(self.overlay))
    if item == nil then
        log.warn("Click ripple: could not add the overlay to scene '%s'.", name)
        return false
    end
    obs.obs_sceneitem_addref(item)
    local info = read_info(item)
    info.pos.x, info.pos.y = 0, 0
    info.scale.x, info.scale.y = 1, 1
    info.rot = 0
    info.alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT)
    info.bounds_type = obs.OBS_BOUNDS_NONE
    set_info(item, info)
    obs.obs_sceneitem_set_locked(item, true)

    -- Directly above the capture item. On failure the overlay stays on top, which is fine.
    local order = nil
    local okp, errp = pcall(function()
        local idx = index_of(scene, anchor)
        if idx ~= nil then
            order = idx + 1
            obs.obs_sceneitem_set_order_position(item, order)
        end
    end)
    if not okp then
        log.debug("Click ripple: could not order the overlay (%s)", tostring(errp))
    end

    self.host = { item = item, id = obs.obs_sceneitem_get_id(item), name = name, grouped = grouped, order = order }
    log.debug("Click overlay added to scene '%s'%s", name, grouped and " (capture is in a group)" or "")
    return true
end

local function hide_slot(self, slot)
    if slot.item ~= nil then
        pcall(obs.obs_sceneitem_set_visible, slot.item, false)
    end
    self.pool:release(slot)
end

---
-- Remove the overlay item from the capture's scene (running ripples are dropped).
function Ripple:detach_host()
    self.blocked = false
    if self.pool ~= nil then
        self.pool:each_active(function(slot) hide_slot(self, slot) end)
    end
    local host = self.host
    if host == nil then
        return
    end
    self.host = nil
    -- If the scene already dropped the item (the user deleted it) there is nothing to remove
    local scene = nil
    pcall(function() scene = obs.obs_sceneitem_get_scene(host.item) end)
    if scene ~= nil then
        local ok, err = pcall(obs.obs_sceneitem_remove, host.item)
        if not ok then
            log.debug("Click overlay remove failed: %s", tostring(err))
        end
    end
    pcall(obs.obs_sceneitem_release, host.item)
    log.debug("Click overlay removed from scene '%s'", host.name)
end

---
-- Start a ripple at a camera-space point (call ensure_host first)
---@param cx number
---@param cy number
---@param now number
function Ripple:spawn(cx, cy, now)
    if self.pool == nil or self.host == nil then
        return
    end
    local slot = self.pool:acquire(now)
    slot.ax, slot.ay = cx, cy
    pcall(obs.obs_sceneitem_set_visible, slot.item, false) -- shown by the first update
end

-- Where a camera-space point is on the canvas: p, the view and content rects, and the group scale k
function Ripple:locate(si, ax, ay)
    local w = si.written
    if w == nil then
        return nil
    end
    local view = { x = w.l, y = w.t, w = w.w, h = w.h }
    local content = geometry.item_content_rect(read_info(si.item), view.w, view.h, self.B)
    local px, py = geometry.camera_to_canvas(ax, ay, view, content)
    local k = 1
    if self.host ~= nil and self.host.grouped and si.group_item ~= nil then
        local gsrc = obs.obs_sceneitem_get_source(si.group_item)
        local gw, gh = obs.obs_source_get_width(gsrc), obs.obs_source_get_height(gsrc)
        if gw > 0 and gh > 0 then
            local gc = geometry.item_content_rect(read_info(si.group_item), gw, gh, self.B)
            px, py = geometry.map_point(px, py, gw, gh, gc)
            k = gc.w / gw
        end
    end
    local inside = ax >= view.x and ax <= view.x + view.w and ay >= view.y and ay <= view.y + view.h
    return { x = px, y = py, k = k, view = view, content = content, inside = inside }
end

local function set_opacity(self, slot, op)
    if slot.filter == nil then
        return
    end
    local v = self.fade == "v1" and math.floor(op * 100 + 0.5) or op
    if slot.op == v then
        return
    end
    slot.op = v
    if self.fade == "v1" then
        obs.obs_data_set_int(slot.fdata, "opacity", v)
    else
        obs.obs_data_set_double(slot.fdata, "opacity", v)
    end
    obs.obs_source_update(slot.filter, slot.fdata)
end

---
-- Advance the running ripples. Call every tick: it re-reads the applied crop, so the ring follows the zoomed view.
---@param si table scene item controller
---@param now number
---@param cam_w number Width of the full camera picture
function Ripple:update(si, now, cam_w)
    if self.pool == nil or not self.pool:any_active() then
        return
    end
    if self.host == nil then
        self.pool:each_active(function(slot) hide_slot(self, slot) end)
        return
    end
    if self.tex_w <= 0 then
        self.tex_w = measure(self)
        if self.tex_w <= 0 then
            self.tex_w = 256
            log.warn("Click ripple: could not read the image size, assuming 256 pixels.")
        end
    end
    local rc = self.cfg
    self.pool:each_active(function(slot)
        local a = anim.sample(now - slot.t0, rc.duration, { opacity = rc.opacity })
        if a.done then
            hide_slot(self, slot)
            return
        end
        local loc = self:locate(si, slot.ax, slot.ay)
        if loc == nil then
            return
        end
        self.last = { ax = slot.ax, ay = slot.ay, p = loc }
        local zoom = rc.zoom_scale and cam_w / loc.view.w or 1
        local d = rc.size * loc.k * zoom * a.scale

        set_opacity(self, slot, a.opacity)
        local info = read_info(slot.item)
        info.pos.x, info.pos.y = loc.x, loc.y
        info.scale.x, info.scale.y = d / self.tex_w, d / self.tex_w
        info.alignment = 0 -- center
        info.rot = 0
        info.bounds_type = obs.OBS_BOUNDS_NONE
        set_info(slot.item, info)
        obs.obs_sceneitem_set_visible(slot.item, loc.inside)
    end)
end

---
-- Remove everything we created: the overlay item, the slots and the overlay scene.
function Ripple:destroy()
    self:detach_host()
    if self.pool ~= nil then
        for _, slot in ipairs(self.pool.slots) do
            slot.active = false
            if slot.filter ~= nil and slot.img ~= nil then
                pcall(obs.obs_source_filter_remove, slot.img, slot.filter)
            end
            if slot.filter ~= nil then pcall(obs.obs_source_release, slot.filter) end
            if slot.fdata ~= nil then pcall(obs.obs_data_release, slot.fdata) end
            if slot.item ~= nil then
                pcall(obs.obs_sceneitem_remove, slot.item)
                pcall(obs.obs_sceneitem_release, slot.item)
            end
            if slot.img ~= nil then pcall(obs.obs_source_release, slot.img) end
            slot.filter, slot.fdata, slot.item, slot.img = nil, nil, nil, nil
        end
    end
    if self.overlay ~= nil then
        pcall(obs.obs_scene_release, self.overlay)
    end
    self.overlay, self.pool, self.path, self.last = nil, nil, nil, nil
end

---
---@param si table|nil scene item controller (for the draw transform cross-check)
---@return table lines for Diagnose
function Ripple:describe(si)
    if self.overlay == nil then
        return { "ripple: off" }
    end
    local lines = { "ripple: image " .. tostring(self.path) .. ", " .. tostring(self.tex_w) .. " px" }
    lines[#lines + 1] = "opacity filter: " .. tostring(self.fade) ..
        (self.fade == "v2" and " (color_filter_v2)" or (self.fade == "v1" and " (color_filter)" or ""))
    local h = self.host
    if h == nil then
        lines[#lines + 1] = "overlay item: not in a scene right now (added on the next click)"
    else
        lines[#lines + 1] = string.format("overlay item: id %s in scene '%s' at order index %s, capture in a group: %s",
            tostring(h.id), tostring(h.name), tostring(h.order), tostring(h.grouped))
    end
    if self.blocked then
        lines[#lines + 1] = "ripple is off for this capture (rotated or flipped)"
    end
    local l = self.last
    if l ~= nil then
        local p = l.p
        lines[#lines + 1] = string.format("last click: camera (%.1f,%.1f) -> canvas (%.1f,%.1f), group scale %.3f",
            l.ax, l.ay, p.x, p.y, p.k)
        lines[#lines + 1] = string.format("  view rect: x=%.1f y=%.1f w=%.1f h=%.1f; content rect: x=%.1f y=%.1f w=%.1f h=%.1f",
            p.view.x, p.view.y, p.view.w, p.view.h, p.content.x, p.content.y, p.content.w, p.content.h)
        if si ~= nil and si.item ~= nil then
            local ok, text = pcall(function()
                local m = obs.matrix4()
                obs.obs_sceneitem_get_draw_transform(si.item, m)
                return string.format("draw transform origin (%.1f,%.1f) vs content rect origin (%.1f,%.1f)",
                    m.t.x, m.t.y, p.content.x, p.content.y)
            end)
            lines[#lines + 1] = "  cross-check: " .. (ok and text or ("unavailable (" .. tostring(text) .. ")"))
        end
    end
    return lines
end

return M
