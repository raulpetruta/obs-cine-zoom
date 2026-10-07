-- Studio scene builder: an inset, rounded, shadowed look on a background, built from two real scenes.
--
--   "OBSCineZoom Studio"        background, shadow and the frame scene (the user switches to this one)
--   "OBSCineZoom Studio Frame"  canvas-sized, holds the capture (SCALE_INNER) and the rounded-corner mask
--
-- The user's own scene is never touched. Padding, radius and shadow only change the frame item in the
-- Studio scene and the generated images, never the capture item, so the zoom code needs no changes: it
-- finds the capture in the frame scene like in any nested scene. Everything is a real, saved source, so
-- "applied" is simply "the Studio scene holds the frame scene": no flag is stored anywhere.
-- This controller keeps no OBS references between calls: it looks things up by name and releases them.
local obs = obslua
local log = require("cinezoom.log")
local png = require("cinezoom.assets.png")
local raster = require("cinezoom.assets.raster")
local checksum = require("cinezoom.assets.checksum")
local layout = require("cinezoom.studio.layout")
local sources = require("cinezoom.obs.sources")
local opt = require("cinezoom.obs.opt")

local M = {}

M.SCENE = "OBSCineZoom Studio"
M.FRAME = "OBSCineZoom Studio Frame"
M.BG = "OBSCineZoom Background"
M.SHADOW = "OBSCineZoom Shadow"
M.MASK = "OBSCineZoom Rounded Corners"

-- Test hook: when set, assets are written to this directory only
M.asset_dir = nil

M.DEBOUNCE = 0.3 -- seconds a changed setting waits before the images are rebuilt

local PREFIX = "obscinezoom-studio-"
local SCENE, FRAME, BG, SHADOW, MASK = M.SCENE, M.FRAME, M.BG, M.SHADOW, M.MASK
local GRADIENT_SIDE = 512 -- longest side of the generated gradient image

local get_info = obs.obs_sceneitem_get_info2 or obs.obs_sceneitem_get_info
local set_info = obs.obs_sceneitem_set_info2 or obs.obs_sceneitem_set_info

local Studio = {}
Studio.__index = Studio

---
---@return table controller (creates nothing until apply)
function M.new()
    return setmetatable({
        last_cfg = nil,         -- copy of cfg.studio the sources were last synced to
        dirty_at = nil,         -- clock time of the latest settings change that still has to be applied
        prev_scene_name = nil,  -- the scene to go back to on remove
        pending_resize = false, -- the layout used a guessed source size
        folder = nil, folder_how = nil, -- folder of the generated images and how it was chosen
        warned = {},
        last = nil,             -- the last computed layout, for Diagnose
    }, Studio)
end

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------
local function round(v)
    return math.floor(v + 0.5)
end

local function file_size(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local size = f:seek("end")
    f:close()
    return size
end

local function join(dir, name)
    if dir:match("[/\\]$") then
        return dir .. name
    end
    return dir .. "/" .. name
end

-- Only files we generated are ever deleted, never an image the user chose
local function is_generated(path)
    local base = type(path) == "string" and path:match("([^/\\]+)$")
    return base ~= nil and base:match("^obscinezoom%-studio%-%a+%-v1%-%x+%.png$") ~= nil
end

local function delete_generated(path)
    if is_generated(path) then
        pcall(os.remove, path)
    end
end

local function warn_once(self, key, fmt, ...)
    if not self.warned[key] then
        self.warned[key] = true
        log.warn(fmt, ...)
    end
end

-- Canvas (base) size, nil when OBS does not tell
local function canvas()
    local ok, w, h = pcall(function()
        local ovi = obs.obs_video_info()
        if obs.obs_get_video_info(ovi) then
            return ovi.base_width, ovi.base_height
        end
    end)
    if ok and w and w > 0 and h > 0 then
        return w, h
    end
    return nil
end

local SETTERS = {
    string = obs.obs_data_set_string, int = obs.obs_data_set_int,
    bool = obs.obs_data_set_bool, double = obs.obs_data_set_double,
}

-- obs_data from a list of {type, key, value}. The caller releases it.
local function make_data(list)
    local d = obs.obs_data_create()
    for _, e in ipairs(list) do
        SETTERS[e[1]](d, e[2], e[3])
    end
    return d
end

-- Set settings on a source and let go of the data
local function update(src, list)
    local d = make_data(list)
    obs.obs_source_update(src, d)
    obs.obs_data_release(d)
end

local function setting(src, key)
    local d = obs.obs_source_get_settings(src)
    if d == nil then
        return ""
    end
    local v = obs.obs_data_get_string(d, key)
    obs.obs_data_release(d)
    return v
end

-- Opaque colour int (0xAABBGGRR) from a colour property value
local function opaque(c)
    return c % 16777216 + 4278190080
end

-- Place an item at the top-left with a uniform scale, optionally inside bounds
local function place(item, t)
    local info = obs.obs_transform_info()
    get_info(item, info)
    info.pos.x, info.pos.y = t.x, t.y
    info.scale.x, info.scale.y = t.scale or 1, t.scale or 1
    info.rot = 0
    info.alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT)
    info.bounds_type = t.bounds_type or obs.OBS_BOUNDS_NONE
    info.bounds_alignment = 0 -- center
    if t.bw ~= nil then
        info.bounds.x, info.bounds.y = t.bw, t.bh
    end
    set_info(item, info)
end

local function clear_crop(item)
    local crop = obs.obs_sceneitem_crop()
    crop.left, crop.top, crop.right, crop.bottom = 0, 0, 0, 0
    obs.obs_sceneitem_set_crop(item, crop)
end

-- Snapshot of the items of a scene (safe to remove items while walking it)
local function items_of(scene)
    local out = {}
    local list = obs.obs_scene_enum_items(scene)
    if list ~= nil then
        for _, it in ipairs(list) do
            out[#out + 1] = it
        end
        obs.sceneitem_list_release(list)
    end
    return out
end

-- Bottom-to-top index (0 = bottom) of an item in a scene, compared by id
local function index_of(scene, item)
    local want = obs.obs_sceneitem_get_id(item)
    for i, it in ipairs(items_of(scene)) do
        if obs.obs_sceneitem_get_id(it) == want then
            return i - 1
        end
    end
    return nil
end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function same(a, b)
    if a == nil or b == nil then
        return false
    end
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

----------------------------------------------------------------------
-- lookup: the scenes and items by name
----------------------------------------------------------------------
-- Returns {studio, frame, frame_src, bg_item, shadow_item, frame_item, held}; release_parts lets go of it
local function lookup()
    local p = { held = {} }
    local function get(name)
        local src = obs.obs_get_source_by_name(name)
        if src ~= nil then
            p.held[#p.held + 1] = src
            if obs.obs_source_is_scene(src) then
                return src, obs.obs_scene_from_source(src)
            end
        end
        return src, nil
    end
    p.studio_src, p.studio = get(SCENE)
    p.frame_src, p.frame = get(FRAME)
    if p.studio ~= nil then
        p.bg_item = obs.obs_scene_find_source(p.studio, BG)
        p.shadow_item = obs.obs_scene_find_source(p.studio, SHADOW)
        p.frame_item = obs.obs_scene_find_source(p.studio, FRAME)
    end
    return p
end

local function release_parts(p)
    for _, s in ipairs(p.held) do
        obs.obs_source_release(s)
    end
    p.held = {}
end

----------------------------------------------------------------------
-- generated files
----------------------------------------------------------------------
local function probe(dir)
    local path = join(dir, PREFIX .. "probe.tmp")
    local f = io.open(path, "wb")
    if f == nil then
        return false
    end
    local ok = f:write("x")
    f:close()
    pcall(os.remove, path)
    return ok ~= nil
end

-- Folders to try, best first: the OBS config folder (survives updates and is per user), the
-- script folder, then the home folder. Each entry is {dir, description}.
local function candidates()
    if M.asset_dir ~= nil then
        return { { M.asset_dir, "test hook" } }
    end
    local list = {}
    local okc, cfgdir = pcall(function()
        local f = opt("os_get_config_path_ptr")
        return f and f("obs-studio/plugin_config")
    end)
    if okc and type(cfgdir) == "string" and cfgdir ~= "" then
        list[#list + 1] = { cfgdir, "os_get_config_path_ptr" }
    end
    local sp = rawget(_G, "script_path")
    if type(sp) == "function" then
        local ok, dir = pcall(sp)
        if ok and type(dir) == "string" and dir ~= "" then
            list[#list + 1] = { dir, "script_path" }
        end
    end
    for _, var in ipairs({ "HOME", "APPDATA" }) do
        local v = os.getenv(var)
        if v ~= nil and v ~= "" then
            list[#list + 1] = { v, "$" .. var }
        end
    end
    return list
end

---
-- The folder generated images go to (nil if none is writable), found by writing a probe file
---@return string|nil dir
---@return string how
function Studio:asset_folder()
    if self.folder ~= nil then
        return self.folder, self.folder_how
    end
    for _, c in ipairs(candidates()) do
        local ok = probe(c[1])
        if not ok then
            local mk = opt("os_mkdirs")
            if mk ~= nil and pcall(mk, c[1]) then
                ok = probe(c[1])
            end
        end
        if ok then
            self.folder, self.folder_how = c[1], c[2]
            return self.folder, self.folder_how
        end
    end
    return nil, "no writable folder"
end

-- Path of a generated image. The name comes from the parameters, so the same look always maps to the
-- same file: it is only written when missing, and a missing file comes back at the same path.
function Studio:asset(kind, params, make)
    local dir = self:asset_folder()
    if dir == nil then
        warn_once(self, "nodir", "Studio look: no folder is writable for the generated images.")
        return nil
    end
    local path = join(dir, string.format("%s%s-v1-%08x.png", PREFIX, kind, checksum.crc32(params) % 4294967296))
    local size = file_size(path)
    if size ~= nil and size > 0 then
        return path
    end
    local bytes = make()
    local f = io.open(path, "wb")
    local ok = f ~= nil and f:write(bytes)
    if f ~= nil then f:close() end
    if not ok then
        pcall(os.remove, path)
        self.folder = nil -- look for another folder next time
        warn_once(self, "write" .. kind, "Studio look: could not write '%s'.", path)
        return nil
    end
    log.debug("Studio image written: %s (%d bytes)", path, #bytes)
    return path
end

----------------------------------------------------------------------
-- parts: background, shadow and mask filter
----------------------------------------------------------------------
-- Make sure a source called `name` of one of `ids` is in `scene`: reuse it, replace one of another kind,
-- or create it (public, so it is saved with the scene collection). The data goes onto an existing source too.
-- Returns the scene item and whether it was newly added.
local function ensure_item(scene, name, ids, list)
    local src = obs.obs_get_source_by_name(name)
    if src ~= nil then
        local id, fits = obs.obs_source_get_id(src), false
        for _, want in ipairs(ids) do
            fits = fits or id == want
        end
        if not fits then
            -- another kind of source with our name (an older version used colour sources): take it out
            -- of our scene and remove it for good. Rename it first: OBS keeps a removed source (and
            -- its name) alive until every reference is gone, and a new source with the same name
            -- would then not be found by name.
            local old = obs.obs_scene_find_source(scene, name)
            if old ~= nil then obs.obs_sceneitem_remove(old) end
            pcall(obs.obs_source_set_name, src, name .. " (old)")
            obs.obs_source_remove(src)
            obs.obs_source_release(src)
            src = nil
        end
    end
    local created = false
    if src == nil then
        for _, id in ipairs(ids) do
            local d = make_data(list)
            src = obs.obs_source_create(id, name, d, nil)
            obs.obs_data_release(d)
            if src ~= nil then break end
        end
        if src == nil then
            error("could not create the source '" .. name .. "'", 0)
        end
        created = true
    else
        update(src, list)
    end
    local item = obs.obs_scene_find_source(scene, name)
    if item == nil then
        item = obs.obs_scene_add(scene, src)
        created = true
    end
    obs.obs_source_release(src)
    if item == nil then
        error("could not add '" .. name .. "' to the scene", 0)
    end
    return item, created
end

-- Leftover copies of our background or shadow (e.g. "OBSCineZoom Background 2", or one renamed to
-- "... (old)") that an earlier version could leave in the Studio scene, possibly covering the picture
local function remove_strays(scene)
    for _, it in ipairs(items_of(scene)) do
        local src = obs.obs_sceneitem_get_source(it)
        local n = src ~= nil and obs.obs_source_get_name(src) or ""
        if n ~= BG and n ~= SHADOW and (n:sub(1, #BG) == BG or n:sub(1, #SHADOW) == SHADOW) then
            log.info("Studio look: removing the leftover source '%s'.", n)
            obs.obs_sceneitem_remove(it)
            local s2 = obs.obs_get_source_by_name(n)
            if s2 ~= nil then
                obs.obs_source_remove(s2)
                obs.obs_source_release(s2)
            end
        end
    end
end

local function image_list(path)
    return { { "string", "file", path or "" }, { "bool", "unload", false } }
end

-- The background source settings. It is always an image source (gradient, solid colour or the user's
-- image), so switching the background type only changes the file and never replaces the source.
local function bg_spec(c, cw, ch, path)
    return { "image_source" }, image_list(path)
end

-- The mask filter on the frame scene: created on first use, updated afterwards. radius 0 turns it off.
local function ensure_mask(frame_src, path, enabled)
    local function list(v2)
        return {
            { "string", "type", "mask_alpha_filter.effect" }, { "string", "image_path", path or "" },
            { "bool", "stretch", true }, { "int", "color", 4294967295 },
            v2 and { "double", "opacity", 1.0 } or { "int", "opacity", 100 },
        }
    end
    local f = obs.obs_source_get_filter_by_name(frame_src, MASK)
    if f == nil then
        for _, id in ipairs({ "mask_filter_v2", "mask_filter" }) do
            local d = make_data(list(id == "mask_filter_v2"))
            f = obs.obs_source_create_private(id, MASK, d)
            obs.obs_data_release(d)
            if f ~= nil then break end
        end
        if f == nil then
            return false
        end
        obs.obs_source_filter_add(frame_src, f) -- the scene holds its own reference now
    else
        update(f, list(obs.obs_source_get_id(f) == "mask_filter_v2"))
    end
    pcall(obs.obs_source_set_enabled, f, enabled) -- missing in very old OBS: the mask then stays on
    obs.obs_source_release(f)
    return true
end

----------------------------------------------------------------------
-- layout and images
----------------------------------------------------------------------
-- Size of the picture in the frame scene: the camera size while we are attached to it (after the user's
-- crop and unaffected by the zoom), else what the source reports. Third result: false when it was guessed.
local function source_size(p, si, cw, ch)
    for _, it in ipairs(items_of(p.frame)) do
        local src = obs.obs_sceneitem_get_source(it)
        if src ~= nil and not obs.obs_source_is_scene(src) then -- the click overlay is a scene
            if si ~= nil and si.ready and si.name == obs.obs_source_get_name(src) and si.cam_w > 0 and si.cam_h > 0 then
                return si.cam_w, si.cam_h, true
            end
            local w, h = obs.obs_source_get_width(src), obs.obs_source_get_height(src)
            if w > 0 and h > 0 then
                return w, h, true
            end
            break
        end
    end
    return cw, ch, false
end

-- Shadow image parameters as one string (the file name is a checksum of it)
local function shadow_key(spec, opacity)
    return string.format("%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.4f", spec.w, spec.h, spec.inner.x, spec.inner.y,
        spec.inner.w, spec.inner.h, spec.r, spec.box, opacity)
end

local function mask_key(m)
    return string.format("%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f", m.w, m.h, m.rect.x, m.rect.y, m.rect.w, m.rect.h, m.r)
end

-- Delete the generated file a source used before, when it now uses another one
local function retire(old, new)
    if old ~= nil and old ~= "" and old ~= new then
        delete_generated(old)
    end
end

---
-- Bring the sources, images and transforms in line with the settings.
---@param c table cfg.studio
---@param si table|nil scene item controller (its camera size is the source size)
---@param opts table|nil {keep_transforms = true} only rebuild images, do not touch positions
function Studio:sync(c, si, opts)
    opts = opts or {}
    local cw, ch = canvas()
    if cw == nil then
        error("the canvas size is unknown", 0)
    end
    local p = lookup()
    local ok, err = pcall(self.sync_parts, self, p, c, si, cw, ch, opts)
    release_parts(p)
    if not ok then
        error(err, 0)
    end
end

function Studio:sync_parts(p, c, si, cw, ch, opts)
    if p.studio == nil or p.frame == nil or p.frame_item == nil then
        error("the studio scenes are incomplete, press Apply studio look again", 0)
    end
    local sw, sh, known = source_size(p, si, cw, ch)
    self.pending_resize = not known

    local content = layout.frame_content(cw, ch, sw, sh)
    local target = layout.target_rect(cw, ch, sw, sh, c.padding)
    local tf = layout.frame_transform(content, target)
    local blur = c.shadow_on and c.shadow_blur or 0
    local srect = layout.shadow_rect(target, blur, 0, c.shadow_offset)
    local mspec = layout.mask_spec(cw, ch, content, tf.scale, c.radius)
    self.last = { cw = cw, ch = ch, sw = sw, sh = sh, known = known, content = content, target = target, tf = tf,
        shadow = srect }

    -- rounded corners: the mask on the frame scene (nothing to draw with radius 0)
    local round_on = c.radius > 0
    local mask_path = nil
    if round_on then
        mask_path = self:asset("mask", mask_key(mspec), function()
            return png.encode(mspec.w, mspec.h, raster.rounded_mask_rgba(mspec.w, mspec.h, mspec.rect, mspec.r))
        end)
    end
    local old_mask = ""
    local mf = obs.obs_source_get_filter_by_name(p.frame_src, MASK)
    if mf ~= nil then
        old_mask = setting(mf, "image_path")
        obs.obs_source_release(mf)
    end
    if not ensure_mask(p.frame_src, mask_path, round_on and mask_path ~= nil) then
        warn_once(self, "mask", "Studio look: no mask filter is available in this OBS, so the corners stay square.")
    end
    retire(old_mask, mask_path)

    -- background
    local bg_path = nil
    if c.bg_type == "gradient" then
        local s = GRADIENT_SIDE / math.max(cw, ch)
        local gw, gh = math.max(1, round(cw * s)), math.max(1, round(ch * s))
        bg_path = self:asset("gradient", string.format("%d,%d,%d,%d,%d", gw, gh, c.color1, c.color2, c.angle), function()
            return png.encode(gw, gh, raster.gradient_rgba(gw, gh, c.color1, c.color2, c.angle))
        end)
    elseif c.bg_type == "color" then
        local col = opaque(c.color1)
        bg_path = self:asset("solid", string.format("%d", col), function()
            return png.encode(16, 16, raster.gradient_rgba(16, 16, col, col, 0))
        end)
    elseif c.bg_type == "image" then
        if c.image ~= "" and file_size(c.image) ~= nil then
            bg_path = c.image
        else
            warn_once(self, "bg" .. c.image, "Studio look: cannot read the background image '%s', using the gradient.", c.image)
            c = copy(c)
            c.bg_type = "gradient"
            return self:sync_parts(p, c, si, cw, ch, opts)
        end
    end
    local old_bg = p.bg_item ~= nil and setting(obs.obs_sceneitem_get_source(p.bg_item), "file") or ""
    local ids, list = bg_spec(c, cw, ch, bg_path)
    local bg_item, fresh = ensure_item(p.studio, BG, ids, list)
    if fresh then
        obs.obs_sceneitem_set_order_position(bg_item, 0)
        obs.obs_sceneitem_set_locked(bg_item, true)
    end
    retire(old_bg, bg_path)
    if not opts.keep_transforms or fresh then
        place(bg_item, { x = 0, y = 0, bounds_type = c.bg_type == "image" and obs.OBS_BOUNDS_SCALE_OUTER
            or obs.OBS_BOUNDS_STRETCH, bw = cw, bh = ch })
    end

    -- shadow
    local shadow_on = c.shadow_on and c.shadow_opacity > 0
    local shadow_path = nil
    if shadow_on then
        local spec = layout.shadow_spec(target, c.shadow_blur, c.radius)
        shadow_path = self:asset("shadow", shadow_key(spec, c.shadow_opacity), function()
            return png.encode(spec.w, spec.h, raster.shadow_rgba(spec, c.shadow_opacity))
        end)
    end
    local shadow_item = p.shadow_item
    if shadow_item == nil then
        shadow_item = ensure_item(p.studio, SHADOW, { "image_source" }, image_list(shadow_path))
        obs.obs_sceneitem_set_order_position(shadow_item, 1)
        obs.obs_sceneitem_set_locked(shadow_item, true)
    else
        local ssrc = obs.obs_sceneitem_get_source(shadow_item)
        retire(setting(ssrc, "file"), shadow_path)
        update(ssrc, image_list(shadow_path))
    end
    obs.obs_sceneitem_set_visible(shadow_item, shadow_path ~= nil)

    -- background, shadow, frame at the bottom in that order (items the user added stay above them)
    for pos, it in ipairs({ bg_item, shadow_item, p.frame_item }) do
        pcall(obs.obs_sceneitem_set_order_position, it, pos - 1)
    end
    remove_strays(p.studio)

    if not opts.keep_transforms then
        place(shadow_item, { x = srect.x, y = srect.y, bounds_type = obs.OBS_BOUNDS_STRETCH, bw = srect.w, bh = srect.h })
        place(p.frame_item, { x = tf.pos_x, y = tf.pos_y, scale = tf.scale })
    end
end

----------------------------------------------------------------------
-- state
----------------------------------------------------------------------
---
-- True when the Studio scene exists and holds the frame scene
---@return boolean
function Studio:is_applied()
    local p = lookup()
    local applied = p.studio ~= nil and p.frame ~= nil and p.frame_item ~= nil
    release_parts(p)
    return applied
end

-- Is name the Studio scene or the frame scene (they must never be the zoom source or the way back)
local function is_ours(name)
    return name == SCENE or name == FRAME
end

-- Name of a scene to go back to: the remembered one if it still exists, else any other scene
function Studio:fallback_scene()
    local found = nil
    if self.prev_scene_name ~= nil and not is_ours(self.prev_scene_name) then
        local s = obs.obs_get_source_by_name(self.prev_scene_name)
        if s ~= nil then
            if obs.obs_source_is_scene(s) then
                found = self.prev_scene_name
            end
            obs.obs_source_release(s)
        end
    end
    if found == nil then
        local list = obs.obs_frontend_get_scenes()
        if list ~= nil then
            for _, s in ipairs(list) do
                local n = obs.obs_source_get_name(s)
                if found == nil and not is_ours(n) then
                    found = n
                end
            end
            obs.source_list_release(list)
        end
    end
    return found
end

local function current_scene_name()
    local cur = obs.obs_frontend_get_current_scene()
    if cur == nil then
        return nil
    end
    local n = obs.obs_source_get_name(cur)
    obs.obs_source_release(cur)
    return n
end

----------------------------------------------------------------------
-- apply
----------------------------------------------------------------------
-- A name taken by something of the wrong kind stops Apply before anything is changed. ids nil: the
-- name must be a scene, otherwise a source of one of ids. Returns true on a clash.
local function name_conflict(name, ids)
    local s = obs.obs_get_source_by_name(name)
    if s == nil then
        return false
    end
    local ok = false
    if ids == nil then
        ok = obs.obs_source_is_scene(s)
    else
        local id = obs.obs_source_get_id(s)
        for _, want in ipairs(ids) do
            ok = ok or id == want
        end
    end
    obs.obs_source_release(s)
    return not ok
end

-- Kinds of source the background and shadow may already be (a leftover of an earlier Apply)
local BG_KINDS = { "color_source_v3", "color_source", "image_source" }

local function build(self, c, cfg, ctx, capture, cw, ch)
    -- the capture goes into the frame scene, which is canvas-sized
    local frame_src, frame, done_frame
    local existing = obs.obs_get_source_by_name(FRAME)
    if existing ~= nil then
        frame_src, frame, done_frame = existing, obs.obs_scene_from_source(existing), function() obs.obs_source_release(existing) end
    else
        frame = obs.obs_scene_create(FRAME)
        if frame == nil then
            error("could not create the scene '" .. FRAME .. "'", 0)
        end
        frame_src, done_frame = obs.obs_scene_get_source(frame), function() obs.obs_scene_release(frame) end
    end
    local studio_src, studio, done_studio
    local ok, err = pcall(function()
        for _, it in ipairs(items_of(frame)) do
            local src = obs.obs_sceneitem_get_source(it)
            -- a capture left from a previous Apply with another zoom source
            if src ~= nil and obs.obs_source_get_name(src) ~= cfg.source and ctx.is_capture ~= nil and ctx.is_capture(src) then
                obs.obs_sceneitem_remove(it)
            end
        end
        local item = obs.obs_scene_find_source(frame, cfg.source) or obs.obs_scene_add(frame, capture)
        if item == nil then
            error("could not add the zoom source to the scene '" .. FRAME .. "'", 0)
        end
        place(item, { x = 0, y = 0, bounds_type = obs.OBS_BOUNDS_SCALE_INNER, bw = cw, bh = ch })
        clear_crop(item)
        obs.obs_sceneitem_set_locked(item, true)

        -- the Studio scene: background, shadow and the frame, in that order, with the user's items above
        local existing_studio = obs.obs_get_source_by_name(SCENE)
        if existing_studio ~= nil then
            studio_src, studio = existing_studio, obs.obs_scene_from_source(existing_studio)
            done_studio = function() obs.obs_source_release(existing_studio) end
        else
            studio = obs.obs_scene_create(SCENE)
            if studio == nil then
                error("could not create the scene '" .. SCENE .. "'", 0)
            end
            studio_src, done_studio = obs.obs_scene_get_source(studio), function() obs.obs_scene_release(studio) end
        end
        local ids, list = bg_spec(c, cw, ch, nil)
        local bg_item = ensure_item(studio, BG, ids, list)
        local shadow_item = ensure_item(studio, SHADOW, { "image_source" }, image_list(nil))
        local frame_item = obs.obs_scene_find_source(studio, FRAME) or obs.obs_scene_add(studio, frame_src)
        if frame_item == nil then
            error("could not add the frame scene to '" .. SCENE .. "'", 0)
        end
        for pos, it in ipairs({ bg_item, shadow_item, frame_item }) do
            obs.obs_sceneitem_set_order_position(it, pos - 1)
            obs.obs_sceneitem_set_locked(it, true)
        end

        self:sync(c, ctx.si)
        local okc, errc = pcall(obs.obs_frontend_set_current_scene, studio_src)
        if not okc then
            log.warn("Studio look: could not switch to the scene '%s' (%s). Select it yourself.", SCENE, tostring(errc))
        end
    end)
    if done_studio ~= nil then done_studio() end
    done_frame()
    if not ok then
        error(err, 0)
    end
end

---
-- Create (or rebuild) the Studio scenes and switch to them.
---@param cfg table settings table (cfg.source, cfg.studio)
---@param ctx table {si, fx, attach, is_capture}
---@return boolean ok
function Studio:apply(cfg, ctx)
    local c = cfg.studio
    if cfg.source == "" or cfg.source == sources.NONE or is_ours(cfg.source) then
        log.warn("Studio look: select a display capture as the Zoom Source first.")
        return false
    end
    local cw, ch = canvas()
    if cw == nil then
        log.warn("Studio look: OBS does not report the canvas size.")
        return false
    end
    local capture = obs.obs_get_source_by_name(cfg.source)
    if capture == nil then
        log.warn("Studio look: the Zoom Source '%s' does not exist.", cfg.source)
        return false
    end
    local ok, err = pcall(function()
        if obs.obs_source_is_scene(capture) then
            error("the Zoom Source must be a capture, not a scene", 0)
        end
        for _, spec in ipairs({ { SCENE }, { FRAME }, { BG, BG_KINDS }, { SHADOW, { "image_source" } } }) do
            if name_conflict(spec[1], spec[2]) then
                error(string.format("'%s' already exists and is not a %s. Rename or remove it first.",
                    spec[1], spec[2] and "background or image source" or "scene"), 0)
            end
        end

        -- nothing of ours may stay on the capture while its scene changes
        ctx.fx:detach_host()
        ctx.si:release()
        local now = current_scene_name()
        if now ~= nil and not is_ours(now) then
            self.prev_scene_name = now
        end

        build(self, c, cfg, ctx, capture, cw, ch)
        self.last_cfg = copy(c)
        self.dirty_at = nil
    end)
    obs.obs_source_release(capture)
    if not ok then
        log.error("Studio look could not be applied: %s", tostring(err))
        pcall(ctx.attach) -- the zoom goes on in whatever scene is current
        return false
    end
    ctx.attach() -- the scene event does not fire when Studio was already current
    log.info("Studio look applied. Scene '%s' is now current.", SCENE)
    return true
end

----------------------------------------------------------------------
-- live updates
----------------------------------------------------------------------
---
-- Call from script_update with the new cfg.studio. The first call only records the baseline.
function Studio:on_settings(c, now)
    local old = self.last_cfg
    if old == nil then
        self.last_cfg = copy(c)
        return
    end
    if same(old, c) then
        return
    end
    self.last_cfg = copy(c)
    if self:is_applied() then
        self.dirty_at = now
        log.debug("Studio settings changed, updating the look shortly")
    else
        log.debug("Studio settings changed; the look is not applied, nothing to update")
    end
end

-- Sync from the tick: an error is logged once and never retried by itself
function Studio:sync_safe(si, why)
    if self.last_cfg == nil then
        return
    end
    local ok, err = pcall(self.sync, self, self.last_cfg, si)
    if not ok then
        self.pending_resize = false
        log.warn("Studio look: %s failed: %s", why, tostring(err))
    else
        log.info("Studio look updated (%s).", why)
    end
end

---
-- Call every tick: applies a settings change once it has been quiet for DEBOUNCE seconds, and finishes a
-- layout that was computed before the capture had a size.
function Studio:tick(now, si)
    if self.dirty_at ~= nil and now - self.dirty_at >= M.DEBOUNCE then
        self.dirty_at = nil
        self:sync_safe(si, "update")
    elseif self.pending_resize and si ~= nil and si.ready then
        self.pending_resize = false
        self:sync_safe(si, "layout update")
    end
end

---
-- The capture changed size: recompute the content rect, the mask and the frame transform
function Studio:on_source_resized(si)
    if self.last_cfg ~= nil and self:is_applied() then
        self:sync_safe(si, "resize")
    end
end

---
-- At load and after a collection change: regenerate generated images that went missing (deleted, or the
-- config moved to another machine). Positions are left alone: the user may have changed them by hand.
function Studio:repair(cfg, si)
    local c = cfg.studio
    if self.last_cfg == nil then
        self.last_cfg = copy(c)
    end
    local p = lookup()
    local missing = false
    if p.studio ~= nil and p.frame ~= nil and p.frame_item ~= nil then
        local paths = {}
        if p.bg_item ~= nil then paths[#paths + 1] = setting(obs.obs_sceneitem_get_source(p.bg_item), "file") end
        if p.shadow_item ~= nil then paths[#paths + 1] = setting(obs.obs_sceneitem_get_source(p.shadow_item), "file") end
        local mf = obs.obs_source_get_filter_by_name(p.frame_src, MASK)
        if mf ~= nil then
            paths[#paths + 1] = setting(mf, "image_path")
            obs.obs_source_release(mf)
        end
        for _, path in ipairs(paths) do
            if is_generated(path) and file_size(path) == nil then
                missing = true
            end
        end
    end
    release_parts(p)
    if missing then
        log.info("Studio look: regenerating missing images.")
        self:sync(c, si, { keep_transforms = true })
    end
end

---
-- A scene collection is about to change: the remembered scene belongs to the old one
function Studio:on_collection_changing()
    self.prev_scene_name = nil
    self.dirty_at = nil
end

----------------------------------------------------------------------
-- remove
----------------------------------------------------------------------
-- Remove the source `name` for good, and its item in `scene` first (OBS drops the rest)
local function remove_source(scene, name)
    local item = scene ~= nil and obs.obs_scene_find_source(scene, name) or nil
    if item ~= nil then
        obs.obs_sceneitem_remove(item)
    end
    local src = obs.obs_get_source_by_name(name)
    if src ~= nil then
        obs.obs_source_remove(src)
        obs.obs_source_release(src)
    end
end

---
-- Take the studio away: everything the script created goes, items the user added to the Studio scene stay.
---@param ctx table {si, fx, attach}
---@return boolean ok
function Studio:remove(ctx)
    local found = lookup()
    local nothing = found.studio_src == nil and found.frame_src == nil
    release_parts(found)
    if nothing then
        log.info("Studio look: there is nothing to remove.")
        return true
    end
    ctx.fx:detach_host()
    ctx.si:release()
    self.dirty_at, self.pending_resize = nil, false
    local ok, err = pcall(function()
        local cur = current_scene_name()
        if cur ~= nil and is_ours(cur) then
            local back = self:fallback_scene()
            local s = back ~= nil and obs.obs_get_source_by_name(back) or nil
            if s == nil then
                error("there is no other scene to switch to. Create one first, then remove the studio look.", 0)
            end
            local okc, errc = pcall(obs.obs_frontend_set_current_scene, s)
            obs.obs_source_release(s)
            if not okc then
                error("could not switch back to '" .. tostring(back) .. "': " .. tostring(errc), 0)
            end
        end

        local p = lookup()
        local paths = {}
        local ok2, err2 = pcall(function()
            -- remember the files before the sources that use them are gone
            if p.bg_item ~= nil then paths[#paths + 1] = setting(obs.obs_sceneitem_get_source(p.bg_item), "file") end
            if p.shadow_item ~= nil then paths[#paths + 1] = setting(obs.obs_sceneitem_get_source(p.shadow_item), "file") end
            if p.frame_src ~= nil then
                local mf = obs.obs_source_get_filter_by_name(p.frame_src, MASK)
                if mf ~= nil then
                    paths[#paths + 1] = setting(mf, "image_path")
                    obs.obs_source_filter_remove(p.frame_src, mf)
                    obs.obs_source_release(mf)
                end
            end
            remove_source(p.studio, BG)
            remove_source(p.studio, SHADOW)
            if p.frame_item ~= nil then
                obs.obs_sceneitem_remove(p.frame_item)
            end
            if p.frame ~= nil then
                for _, it in ipairs(items_of(p.frame)) do
                    obs.obs_sceneitem_remove(it)
                end
            end
        end)
        if not ok2 then
            release_parts(p) -- the scenes stay: something could not be taken out of them
            error(err2, 0)
        end
        -- the scenes: the frame scene is ours alone, the Studio scene stays if the user put items in it
        local studio_left = p.studio ~= nil and #items_of(p.studio) or 0
        local studio_src, frame_src = p.studio_src, p.frame_src
        if frame_src ~= nil then
            obs.obs_source_remove(frame_src)
        end
        if studio_src ~= nil then
            if studio_left == 0 then
                obs.obs_source_remove(studio_src)
            else
                log.info("Studio look removed. The scene '%s' stays because it holds %d item(s) you added.",
                    SCENE, studio_left)
            end
        end
        release_parts(p)
        for _, path in ipairs(paths) do
            delete_generated(path)
        end
    end)
    self.last = nil
    if not ok then
        log.error("Studio look could not be removed completely: %s", tostring(err))
    else
        log.info("Studio look removed.")
    end
    pcall(ctx.attach)
    return ok
end

----------------------------------------------------------------------
-- Diagnose
----------------------------------------------------------------------
local function guard(lines, label, fn)
    local ok, err = pcall(fn)
    if not ok then
        lines[#lines + 1] = label .. ": unavailable (" .. tostring(err) .. ")"
    end
end

local function item_line(scene, name, item)
    local info = obs.obs_transform_info()
    get_info(item, info)
    local src = obs.obs_sceneitem_get_source(item)
    return string.format("item '%s': id %s, order index %s, locked %s, visible %s, pos=(%.1f,%.1f) scale=(%.3f,%.3f) " ..
        "bounds_type=%s bounds=(%.1f,%.1f)", name, tostring(obs.obs_source_get_id(src)), tostring(index_of(scene, item)),
        tostring(obs.obs_sceneitem_locked(item)), tostring(obs.obs_sceneitem_visible(item)), info.pos.x, info.pos.y,
        info.scale.x, info.scale.y, tostring(info.bounds_type), info.bounds.x, info.bounds.y)
end

local function rect_text(r)
    return string.format("x=%.1f y=%.1f w=%.1f h=%.1f", r.x, r.y, r.w, r.h)
end

---
---@param si table|nil scene item controller
---@return table lines for Diagnose
function Studio:describe(si)
    local lines = {}
    local p = lookup()
    local ok, err = pcall(function()
        local applied = p.studio ~= nil and p.frame ~= nil and p.frame_item ~= nil
        lines[#lines + 1] = string.format("applied: %s (scene '%s': %s, frame scene '%s': %s)", tostring(applied),
            SCENE, p.studio_src and "found" or "missing", FRAME, p.frame_src and "found" or "missing")
        local cw, ch = canvas()
        lines[#lines + 1] = "canvas: " .. (cw and (cw .. "x" .. ch) or "unknown")
        lines[#lines + 1] = "os_get_config_path_ptr available: " .. tostring(opt("os_get_config_path_ptr") ~= nil)
        if not applied then
            lines[#lines + 1] = "studio look is off (nothing created, no folder probed)"
            return
        end
        -- only now: this writes a small probe file
        local dir, how = self:asset_folder()
        lines[#lines + 1] = string.format("asset directory: %s (chosen via %s)", tostring(dir), tostring(how))

        local l = self.last
        if l ~= nil then
            lines[#lines + 1] = string.format("source size used: %dx%d (%s)", l.sw, l.sh,
                l.known and "measured" or "guessed, waiting for the first frame")
            lines[#lines + 1] = "content rect in the frame scene: " .. rect_text(l.content)
            lines[#lines + 1] = "target rect on the canvas: " .. rect_text(l.target)
            lines[#lines + 1] = string.format("frame transform: scale %.4f, pos (%.1f,%.1f)", l.tf.scale, l.tf.pos_x, l.tf.pos_y)
            lines[#lines + 1] = "shadow rect: " .. rect_text(l.shadow)
        else
            lines[#lines + 1] = "layout: not computed in this session yet"
        end

        local paths = {}
        for _, e in ipairs({ { p.bg_item, BG }, { p.shadow_item, SHADOW }, { p.frame_item, FRAME } }) do
            guard(lines, e[2], function()
                if e[1] == nil then
                    lines[#lines + 1] = "item '" .. e[2] .. "': missing"
                    return
                end
                lines[#lines + 1] = item_line(p.studio, e[2], e[1])
                local src = obs.obs_sceneitem_get_source(e[1])
                if e[2] ~= FRAME then
                    paths[#paths + 1] = setting(src, "file")
                end
                if e[2] == BG then
                    local id = obs.obs_source_get_id(src)
                    lines[#lines + 1] = "background source id: " .. tostring(id)
                end
            end)
        end
        guard(lines, "mask filter", function()
            local mf = obs.obs_source_get_filter_by_name(p.frame_src, MASK)
            if mf == nil then
                lines[#lines + 1] = "mask filter: missing"
                return
            end
            local d = obs.obs_source_get_settings(mf)
            lines[#lines + 1] = string.format("mask filter: id %s, enabled %s, settings %s", tostring(obs.obs_source_get_id(mf)),
                tostring(obs.obs_source_enabled(mf)), tostring(obs.obs_data_get_json(d)))
            paths[#paths + 1] = setting(mf, "image_path")
            obs.obs_data_release(d)
            obs.obs_source_release(mf)
        end)
        guard(lines, "capture", function()
            for _, it in ipairs(items_of(p.frame)) do
                local src = obs.obs_sceneitem_get_source(it)
                if obs.obs_source_is_scene(src) then
                    lines[#lines + 1] = item_line(p.frame, "overlay in frame scene", it)
                else
                    lines[#lines + 1] = item_line(p.frame, "capture in frame scene", it)
                    local names = {}
                    local filters = obs.obs_source_enum_filters(src)
                    if filters ~= nil then
                        for _, f in ipairs(filters) do
                            names[#names + 1] = obs.obs_source_get_name(f)
                        end
                        obs.source_list_release(filters)
                    end
                    lines[#lines + 1] = "capture filters, in order: " .. (#names > 0 and table.concat(names, ", ") or "none")
                end
            end
        end)
        for _, path in ipairs(paths) do
            if path ~= "" then
                local size = file_size(path)
                local writable = false
                local f = io.open(path, "ab")
                if f ~= nil then
                    writable = true
                    f:close()
                end
                lines[#lines + 1] = string.format("image: %s, exists %s, %s bytes, writable %s, generated %s", path,
                    tostring(size ~= nil), tostring(size), tostring(writable), tostring(is_generated(path)))
            end
        end
        local cur = current_scene_name()
        lines[#lines + 1] = "current scene is the Studio scene: " .. tostring(cur == SCENE)
        local in_frame = false
        if si ~= nil and si.item ~= nil then
            local sc = obs.obs_sceneitem_get_scene(si.item)
            in_frame = sc ~= nil and obs.obs_source_get_name(obs.obs_scene_get_source(sc)) == FRAME
        end
        lines[#lines + 1] = "zoom item is in the frame scene: " .. tostring(in_frame)
        lines[#lines + 1] = "pending resize: " .. tostring(self.pending_resize)
    end)
    release_parts(p)
    if not ok then
        lines[#lines + 1] = "could not describe the studio: " .. tostring(err)
    end
    return lines
end

return M
