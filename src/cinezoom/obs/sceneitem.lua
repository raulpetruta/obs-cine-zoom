-- Scene item and crop filter management. This is the proven part of the original script
-- (nested-scene search, transform-crop to crop-filter conversion, bounding box conversion,
-- release), restructured into an object so it holds no globals. What changed:
--   * a source whose size is still 0 (ScreenCaptureKit before its first frame) is attached
--     but not set up; poll_size() finishes the setup when the real size arrives
--   * the camera size and the user's crop are exposed so the math lives in geometry.lua
local obs = obslua
local log = require("cinezoom.log")

local M = {}

M.FILTER_NAME = "cinezoom-crop"

-- Older OBS versions only have the v1 transform functions
local get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local SceneItem = {}
SceneItem.__index = SceneItem

---
---@return table scene item controller
function M.new()
    return setmetatable({
        name = "",
        source = nil,
        item = nil,
        ready = false,       -- true once the source has a size and the crop filter exists
        setup_done = false,
        is_capture = true,
        info_orig = nil,     -- transform to restore on release
        crop_orig = nil,     -- transform crop to restore on release
        converted_crop = nil, -- {l,t,r,b} transform crop we turned into a filter
        filter = nil,
        filter_temp = nil,
        filter_settings = nil,
        group_item = nil,    -- the group's own item when the capture sits inside a group (we hold a reference)
        base_w = 0, base_h = 0, -- source size before any filter
        cam_w = 0, cam_h = 0,   -- size of the picture the camera moves over
        user_crop = { x = 0, y = 0, w = 0, h = 0 }, -- crop already applied by the user, in source pixels
        written = nil,
    }, SceneItem)
end

---
-- Breadth-first search for the scene item of `name`, starting at the current scene and
-- looking into nested scenes and groups. Returns an item with its own reference, or nil.
-- When the item was found inside a group, the group's item in its parent scene comes second
-- (also with its own reference).
local function find_scene_item_by_name(root_scene, name)
    local queue = { { scene = root_scene } }

    -- Entries still waiting hold a reference to their group item
    local function drop(entries)
        for _, e in ipairs(entries) do
            if e.group_item ~= nil then
                obs.obs_sceneitem_release(e.group_item)
            end
        end
    end

    while #queue > 0 do
        local entry = table.remove(queue, 1)
        local s = entry.scene
        log.debug("Looking in scene '%s'", obs.obs_source_get_name(obs.obs_scene_get_source(s)))

        -- Check if the current scene has the target scene item
        local found = obs.obs_scene_find_source(s, name)
        if found ~= nil then
            log.debug("Found sceneitem '%s'", name)
            obs.obs_sceneitem_addref(found)
            drop(queue)
            return found, entry.group_item
        end

        -- If the current scene has nested scenes, enqueue them for later examination
        local all_items = obs.obs_scene_enum_items(s)
        if all_items then
            for _, item in pairs(all_items) do
                local nested = obs.obs_sceneitem_get_source(item)
                if nested ~= nil then
                    if obs.obs_source_is_scene(nested) then
                        queue[#queue + 1] = { scene = obs.obs_scene_from_source(nested) }
                    elseif obs.obs_source_is_group(nested) then
                        obs.obs_sceneitem_addref(item)
                        queue[#queue + 1] = { scene = obs.obs_group_from_source(nested), group_item = item }
                    end
                end
            end
            obs.sceneitem_list_release(all_items)
        end
        drop({ entry })
    end

    return nil
end

---
-- Undo everything we changed and let go of all OBS references
function SceneItem:release()
    self.ready = false
    self.setup_done = false
    self.converted_crop = nil
    self.written = nil

    if self.item ~= nil then
        if self.filter ~= nil and self.source ~= nil then
            log.debug("Zoom crop filter removed")
            obs.obs_source_filter_remove(self.source, self.filter)
        end
        if self.filter_temp ~= nil and self.source ~= nil then
            log.debug("Conversion crop filter removed")
            obs.obs_source_filter_remove(self.source, self.filter_temp)
        end

        if self.info_orig ~= nil then
            log.debug("Transform info reset back to original")
            set_info(self.item, self.info_orig)
        end
        if self.crop_orig ~= nil then
            log.debug("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(self.item, self.crop_orig)
        end

        obs.obs_sceneitem_release(self.item)
    end
    if self.group_item ~= nil then
        obs.obs_sceneitem_release(self.group_item)
    end

    if self.filter ~= nil then
        obs.obs_source_release(self.filter)
    end
    if self.filter_temp ~= nil then
        obs.obs_source_release(self.filter_temp)
    end
    if self.filter_settings ~= nil then
        obs.obs_data_release(self.filter_settings)
    end
    if self.source ~= nil then
        obs.obs_source_release(self.source)
    end

    self.item, self.source, self.group_item = nil, nil, nil
    self.filter, self.filter_temp, self.filter_settings = nil, nil, nil
    self.info_orig, self.crop_orig = nil, nil
    self.base_w, self.base_h, self.cam_w, self.cam_h = 0, 0, 0, 0
end

---
-- Source size before filters. At load time some sources only answer through
-- obs_source_get_width, so that is the fallback until our own filter exists.
function SceneItem:base_size()
    local w = obs.obs_source_get_base_width(self.source)
    local h = obs.obs_source_get_base_height(self.source)
    if (w == 0 or h == 0) and not self.setup_done then
        w = obs.obs_source_get_width(self.source)
        h = obs.obs_source_get_height(self.source)
    end
    return w, h
end

---
-- Find the scene item for `name` in the current scene and prepare it for zooming.
---@param name string Source name
---@param is_capture function|nil classify(source) -> boolean, true for real display captures
---@return boolean attached
function SceneItem:attach(name, is_capture)
    self:release()
    self.name = name

    -- Get a matching source we can use for zooming in the current scene
    log.debug("Finding sceneitem for Zoom Source '%s'", name)
    local source = obs.obs_get_source_by_name(name)
    if source == nil then
        log.warn("Zoom source '%s' does not exist.", name)
        return false
    end

    local item, group_item = nil, nil
    local scene_source = obs.obs_frontend_get_current_scene()
    if scene_source ~= nil then
        -- Start at the current scene and use a BFS to look into any nested scenes
        item, group_item = find_scene_item_by_name(obs.obs_scene_from_source(scene_source), name)
        obs.obs_source_release(scene_source)
    end

    if item == nil then
        log.warn("Source '%s' is not part of the current scene hierarchy. " ..
            "Try selecting a different zoom source or switching scenes.", name)
        obs.obs_source_release(source)
        return false
    end

    self.source = source
    self.item = item
    self.group_item = group_item
    self.is_capture = is_capture == nil or is_capture(source)

    -- Capture the original settings so we can restore them later
    self.info_orig = obs.obs_transform_info()
    get_info(item, self.info_orig)
    self.crop_orig = obs.obs_sceneitem_crop()
    obs.obs_sceneitem_get_crop(item, self.crop_orig)

    if not self.is_capture then
        -- Non-display-capture sources don't correctly report crop values
        self.crop_orig.left, self.crop_orig.top, self.crop_orig.right, self.crop_orig.bottom = 0, 0, 0, 0
    end

    self:try_setup()
    return true
end

---
-- Sum of the non-relative crop filters the user already has (ours are skipped).
-- Returns nil if there are none.
function SceneItem:scan_user_crop()
    local crop = nil
    local filters = obs.obs_source_enum_filters(self.source)
    if filters == nil then
        return nil
    end

    for _, f in pairs(filters) do
        if obs.obs_source_get_id(f) == "crop_filter" then
            local fname = obs.obs_source_get_name(f)
            if fname ~= M.FILTER_NAME and fname ~= "temp_" .. M.FILTER_NAME then
                local settings = obs.obs_source_get_settings(f)
                if settings ~= nil then
                    if not obs.obs_data_get_bool(settings, "relative") then
                        crop = crop or { x = 0, y = 0, w = 0, h = 0 }
                        crop.x = crop.x + obs.obs_data_get_int(settings, "left")
                        crop.y = crop.y + obs.obs_data_get_int(settings, "top")
                        crop.w = crop.w + obs.obs_data_get_int(settings, "cx")
                        crop.h = crop.h + obs.obs_data_get_int(settings, "cy")
                        log.debug("Found existing non-relative crop/pad filter (%s)", fname)
                    else
                        log.warn("Found existing relative crop/pad filter (%s). " ..
                            "This will cause issues with zooming. Convert to non-relative settings instead.", fname)
                    end
                    obs.obs_data_release(settings)
                end
            end
        end
    end

    obs.source_list_release(filters)
    return crop
end

---
-- One-time setup once the source size is known: convert the transform to a bounding box,
-- turn a transform crop into a crop filter, and create our own crop filter.
function SceneItem:setup()
    local bw, bh = self:base_size()
    local item = self.item

    local user_crop = self:scan_user_crop()
    local c = self.crop_orig

    -- If the user has a transform crop set, we need to convert it into a crop filter so that
    -- it works correctly with zooming. Ideally the user does this manually.
    if not user_crop and (c.left ~= 0 or c.top ~= 0 or c.right ~= 0 or c.bottom ~= 0) then
        log.debug("Creating new crop filter")
        local settings = obs.obs_data_create()
        obs.obs_data_set_bool(settings, "relative", false)
        obs.obs_data_set_int(settings, "left", c.left)
        obs.obs_data_set_int(settings, "top", c.top)
        obs.obs_data_set_int(settings, "cx", bw - (c.left + c.right))
        obs.obs_data_set_int(settings, "cy", bh - (c.top + c.bottom))
        self.filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. M.FILTER_NAME, settings)
        obs.obs_source_filter_add(self.source, self.filter_temp)
        obs.obs_data_release(settings)
        self.converted_crop = { l = c.left, t = c.top, r = c.right, b = c.bottom }

        -- Clear out the transform crop
        local cleared = obs.obs_sceneitem_crop()
        cleared.left, cleared.top, cleared.right, cleared.bottom = 0, 0, 0, 0
        obs.obs_sceneitem_set_crop(item, cleared)

        log.warn("Found existing transform crop. This may cause issues with zooming. " ..
            "It has been converted to a crop/pad filter instead. " ..
            "If you have issues with your layout consider making the filter manually.")
    end

    -- Convert a plain transform into a bounding box one we can zoom inside of.
    -- The box is sized from the picture AFTER the crop, so the layout does not change.
    local info = obs.obs_transform_info()
    get_info(item, info)
    if info.bounds_type == obs.OBS_BOUNDS_NONE then
        local pw, ph = bw, bh
        if user_crop then
            pw, ph = user_crop.w, user_crop.h
        elseif self.converted_crop then
            local cc = self.converted_crop
            pw, ph = bw - (cc.l + cc.r), bh - (cc.t + cc.b)
        end
        info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
        info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)
        info.bounds.x = pw * info.scale.x
        info.bounds.y = ph * info.scale.y
        set_info(item, info)

        log.warn("Found existing non-boundingbox transform. This may cause issues with zooming. " ..
            "It has been converted to a bounding box scaling transform instead. " ..
            "If you have issues with your layout consider making the transform use a bounding box manually.")
    end

    -- Get or create our crop filter that we change during zoom
    self.filter = obs.obs_source_get_filter_by_name(self.source, M.FILTER_NAME)
    if self.filter == nil then
        self.filter_settings = obs.obs_data_create()
        obs.obs_data_set_bool(self.filter_settings, "relative", false)
        self.filter = obs.obs_source_create_private("crop_filter", M.FILTER_NAME, self.filter_settings)
        obs.obs_source_filter_add(self.source, self.filter)
    else
        self.filter_settings = obs.obs_source_get_settings(self.filter)
    end
    obs.obs_source_filter_set_order(self.source, self.filter, obs.OBS_ORDER_MOVE_BOTTOM)

    self.setup_done = true
end

---
-- Recompute base size, the user's crop and the camera size from the live source
function SceneItem:recompute()
    local bw, bh = self:base_size()
    self.base_w, self.base_h = bw, bh

    local crop = self:scan_user_crop()
    if crop then
        self.user_crop = crop
    elseif self.converted_crop then
        local cc = self.converted_crop
        self.user_crop = { x = cc.l, y = cc.t, w = bw - (cc.l + cc.r), h = bh - (cc.t + cc.b) }
    else
        self.user_crop = { x = 0, y = 0, w = bw, h = bh }
    end
    self.cam_w, self.cam_h = self.user_crop.w, self.user_crop.h

    log.debug("Source size %dx%d, camera %dx%d (user crop at %d,%d)",
        bw, bh, self.cam_w, self.cam_h, self.user_crop.x, self.user_crop.y)

    -- Start from the full picture
    self.written = nil
    self:set_crop({ x = 0, y = 0, w = self.cam_w, h = self.cam_h })
end

---
-- Finish setup if the source has a size yet. Returns true when ready.
function SceneItem:try_setup()
    if self.item == nil then
        return false
    end
    local w, h = self:base_size()
    if w == 0 or h == 0 then
        log.debug("Source size is still 0, waiting for the first frame")
        return false
    end
    if not self.setup_done then
        self:setup()
    end
    self:recompute()
    self.ready = true
    return true
end

---
-- Call every tick. Finishes a deferred setup and notices a changed source size.
---@return boolean changed True when the size became known or changed (callers re-resolve the display)
function SceneItem:poll_size()
    if self.item == nil then
        return false
    end
    if not self.ready then
        return self:try_setup()
    end
    local w = obs.obs_source_get_base_width(self.source)
    local h = obs.obs_source_get_base_height(self.source)
    if w > 0 and h > 0 and (w ~= self.base_w or h ~= self.base_h) then
        log.info("Source size changed to %dx%d", w, h)
        self:recompute()
        return true
    end
    return false
end

---
-- Write the crop filter. Values are floored here and only here.
---@param rect table {x, y, w, h} in camera space
function SceneItem:set_crop(rect)
    if self.filter == nil or self.filter_settings == nil then
        return
    end
    local l, t = math.floor(rect.x), math.floor(rect.y)
    local w, h = math.max(1, math.floor(rect.w)), math.max(1, math.floor(rect.h))

    local last = self.written
    if last and last.l == l and last.t == t and last.w == w and last.h == h then
        return -- unchanged, skip the call into OBS
    end
    self.written = { l = l, t = t, w = w, h = h }

    obs.obs_data_set_int(self.filter_settings, "left", l)
    obs.obs_data_set_int(self.filter_settings, "top", t)
    obs.obs_data_set_int(self.filter_settings, "cx", w)
    obs.obs_data_set_int(self.filter_settings, "cy", h)
    obs.obs_source_update(self.filter, self.filter_settings)
end

---
-- Human readable lines about the item, for Diagnose
---@return table lines
function SceneItem:describe()
    local lines = {}
    if self.source == nil then
        return { "no scene item attached" }
    end
    lines[#lines + 1] = string.format("source: %s (id %s)", self.name, tostring(obs.obs_source_get_id(self.source)))
    local okj, json = pcall(function()
        local s = obs.obs_source_get_settings(self.source)
        local j = obs.obs_data_get_json(s)
        obs.obs_data_release(s)
        return j
    end)
    lines[#lines + 1] = "source settings: " .. (okj and tostring(json) or "(unavailable)")
    lines[#lines + 1] = string.format("base size: %dx%d, camera size: %dx%d, ready: %s",
        self.base_w, self.base_h, self.cam_w, self.cam_h, tostring(self.ready))
    lines[#lines + 1] = string.format("user crop: x=%d y=%d w=%d h=%d",
        self.user_crop.x, self.user_crop.y, self.user_crop.w, self.user_crop.h)
    lines[#lines + 1] = "transform crop converted to filter: " .. tostring(self.converted_crop ~= nil)

    local names = {}
    local filters = obs.obs_source_enum_filters(self.source)
    if filters ~= nil then
        for _, f in pairs(filters) do
            names[#names + 1] = obs.obs_source_get_name(f) .. " (" .. obs.obs_source_get_id(f) .. ")"
        end
        obs.source_list_release(filters)
    end
    lines[#lines + 1] = "filters: " .. (#names > 0 and table.concat(names, ", ") or "none")

    if self.item ~= nil then
        local info = obs.obs_transform_info()
        get_info(self.item, info)
        lines[#lines + 1] = string.format(
            "transform: pos=(%.1f,%.1f) scale=(%.3f,%.3f) rot=%.1f bounds_type=%s bounds=(%.1f,%.1f)",
            info.pos.x, info.pos.y, info.scale.x, info.scale.y, info.rot,
            tostring(info.bounds_type), info.bounds.x, info.bounds.y)
    end
    return lines
end

return M
