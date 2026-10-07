-- A fake `obslua` for tests: just enough of the OBS Lua API (same function names as the
-- real SWIG bindings) to drive the script end to end, with reference counting so tests can
-- check that everything acquired is released again.
--
-- usage: local obs, world = require("stub_obslua").new()
local M = {}

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = deep_copy(x) end
    return c
end

local function copy_into(dst, src)
    for k, v in pairs(src) do dst[k] = deep_copy(v) end
end

function M.new()
    local obs = {}
    local world = {
        logs = {}, hotkeys = {}, next_hotkey = 1, frontend_callbacks = {},
        sources = {}, scene_source = nil, transitions = {},
        refs = 0, data_live = 0, signal_connections = 0, update_calls = 0,
        version = "31.0.0",
        private = {},          -- every private source/filter/scene ever created (refs must end at 0)
        channels = {},         -- output channels: index -> source (the channel holds a reference)
        media_restarts = 0,    -- obs_source_media_restart calls
        next_item_id = 1,
        unavailable_ids = {},  -- source ids obs_source_create_private / obs_source_create fail for (return nil)
        canvas = { w = 1920, h = 1080 }, -- base canvas size obs_get_video_info reports
    }

    -- constants
    obs.OBS_LOG_ERROR, obs.OBS_LOG_WARNING, obs.OBS_LOG_INFO = 100, 200, 300
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING = 2, 2
    obs.OBS_GROUP_NORMAL, obs.OBS_GROUP_CHECKABLE = 1, 2
    obs.OBS_TEXT_INFO = 3
    -- same values as libobs (STRETCH is 1, SCALE_INNER is 2)
    obs.OBS_BOUNDS_NONE, obs.OBS_BOUNDS_STRETCH, obs.OBS_BOUNDS_SCALE_INNER = 0, 1, 2
    obs.OBS_BOUNDS_SCALE_OUTER, obs.OBS_BOUNDS_SCALE_TO_WIDTH = 3, 4
    obs.OBS_BOUNDS_SCALE_TO_HEIGHT, obs.OBS_BOUNDS_MAX_ONLY = 5, 6
    obs.OBS_ORDER_MOVE_BOTTOM = 3
    obs.OBS_FRONTEND_EVENT_SCENE_CHANGED = 1
    obs.OBS_FRONTEND_EVENT_FINISHED_LOADING = 2
    obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN = 3
    obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING = 4
    obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED = 5
    obs.OBS_FRONTEND_EVENT_EXIT = 6
    obs.OBS_MONITORING_TYPE_NONE, obs.OBS_MONITORING_TYPE_MONITOR_ONLY = 0, 1
    obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT = 2
    obs.OBS_PATH_FILE = 0
    obs.OBS_MEDIA_STATE_NONE, obs.OBS_MEDIA_STATE_PLAYING = 0, 1

    function obs.script_log(level, msg) world.logs[#world.logs + 1] = { level = level, msg = msg } end
    function obs.obs_get_version_string() return world.version end

    ------------------------------------------------------------------ obs_data
    local function new_data() world.data_live = world.data_live + 1; return { vals = {}, defs = {} } end
    function obs.obs_data_create() return new_data() end
    function obs.obs_data_release(d) assert(d, "release of nil data"); world.data_live = world.data_live - 1 end
    local function getter(zero)
        return function(d, k)
            local v = d.vals[k]
            if v == nil then v = d.defs[k] end
            if v == nil then return zero end
            return v
        end
    end
    obs.obs_data_get_string, obs.obs_data_get_int = getter(""), getter(0)
    obs.obs_data_get_double, obs.obs_data_get_bool = getter(0), getter(false)
    for _, kind in ipairs({ "string", "int", "double", "bool" }) do
        obs["obs_data_set_" .. kind] = function(d, k, v) d.vals[k] = v end
        obs["obs_data_set_default_" .. kind] = function(d, k, v) d.defs[k] = v end
    end
    function obs.obs_data_get_array(d, k) return d.vals[k] or {} end
    function obs.obs_data_set_array(d, k, a) d.vals[k] = a end
    function obs.obs_data_array_release() end
    function obs.obs_data_get_json(d)
        local parts = {}
        for k, v in pairs(d.vals) do parts[#parts + 1] = string.format("%q:%q", k, tostring(v)) end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end

    ------------------------------------------------------------------ hotkeys
    function obs.obs_hotkey_register_frontend(name, desc, cb)
        assert(type(cb) == "function", "hotkey callback must be a function")
        local id = world.next_hotkey
        world.next_hotkey = id + 1
        world.hotkeys[id] = { name = name, desc = desc, cb = cb }
        return id
    end
    function obs.obs_hotkey_load(id) assert(world.hotkeys[id], "load of unknown hotkey") end
    function obs.obs_hotkey_save(id) assert(world.hotkeys[id], "save of unknown hotkey"); return { id } end
    function obs.obs_hotkey_unregister(id)
        assert(type(id) == "number", "obs_hotkey_unregister takes the hotkey id")
        world.hotkeys[id] = nil
    end
    function world.press(name)
        for _, h in pairs(world.hotkeys) do
            if h.name == name then h.cb(true); h.cb(false); return end
        end
        error("no hotkey " .. name)
    end

    ------------------------------------------------------------------ frontend / signals
    function obs.obs_frontend_get_current_scene()
        if world.scene_source then world.scene_source.refs = world.scene_source.refs + 1 end
        return world.scene_source
    end
    -- Switching scenes fires SCENE_CHANGED like OBS does, but only when the scene really changes
    function obs.obs_frontend_set_current_scene(src)
        assert(src, "set_current_scene of nil")
        world.scene_switches = (world.scene_switches or 0) + 1
        if world.scene_source ~= src then
            world.scene_source = src
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_CHANGED)
        end
    end
    function obs.obs_frontend_get_scenes()
        local list = {}
        for _, s in ipairs(world.sources) do
            if s.id == "scene" and not s.removed then s.refs = s.refs + 1; list[#list + 1] = s end
        end
        return list
    end
    function obs.obs_frontend_add_event_callback(cb) world.frontend_callbacks[cb] = true end
    function obs.obs_frontend_remove_event_callback(cb) world.frontend_callbacks[cb] = nil end
    function world.fire_event(e) for cb in pairs(world.frontend_callbacks) do cb(e) end end
    function obs.obs_frontend_get_transitions()
        for _, t in ipairs(world.transitions) do t.refs = t.refs + 1 end
        return world.transitions
    end
    function obs.obs_source_get_signal_handler(s) return s.handler end
    function obs.signal_handler_connect(h, sig, cb) h[sig] = cb; world.signal_connections = world.signal_connections + 1 end
    function obs.signal_handler_disconnect(h, sig, cb)
        assert(h[sig] == cb, "disconnect of a handler that was not connected")
        h[sig] = nil
        world.signal_connections = world.signal_connections - 1
    end
    function obs.source_list_release(list) for _, s in ipairs(list) do s.refs = s.refs - 1 end end
    function obs.sceneitem_list_release() end

    ------------------------------------------------------------------ sources
    function world.add_source(def)
        local s = {
            id = def.id, name = def.name, refs = 1, base_w = def.base_w or 0, base_h = def.base_h or 0,
            settings = new_data(), filters = {}, handler = {}, prop_items = def.prop_items or {}, kind = "source",
        }
        for k, v in pairs(def.settings or {}) do s.settings.vals[k] = v end
        world.sources[#world.sources + 1] = s
        return s
    end
    function obs.obs_source_release(s) assert(s, "release of nil source"); s.refs = s.refs - 1 end
    function obs.obs_source_get_name(s) return s.name end
    function obs.obs_source_get_id(s) return s.id end
    function obs.obs_get_source_by_name(name)
        for _, s in ipairs(world.sources) do
            if s.name == name and not s.removed then s.refs = s.refs + 1; return s end
        end
        return nil
    end
    local function live_sources()
        local list = {}
        for _, s in ipairs(world.sources) do
            if not s.removed then list[#list + 1] = s end
        end
        return list
    end
    function obs.obs_enum_sources()
        local list = live_sources()
        for _, s in ipairs(list) do s.refs = s.refs + 1 end
        return list
    end
    function obs.obs_source_get_base_width(s) return s.base_w end
    function obs.obs_source_get_base_height(s) return s.base_h end
    function obs.obs_source_get_width(s) return s.base_w end
    function obs.obs_source_get_height(s) return s.base_h end
    function obs.obs_source_get_settings(s) world.data_live = world.data_live + 1; return s.settings end
    function obs.obs_source_is_scene(s) return s.id == "scene" end
    function obs.obs_source_is_group(s) return s.id == "group" end

    -- private sources and filters (never listed, never saved)
    local FILTER_IDS = { crop_filter = true, color_filter = true, color_filter_v2 = true, mask_filter = true,
        mask_filter_v2 = true }
    local function png_size(path)
        local f = io.open(path, "rb")
        if not f then return 0, 0 end
        local head = f:read(24)
        f:close()
        if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then return 0, 0 end
        local function be(i) local a, b, c, d = head:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
        return be(17), be(21)
    end
    -- size an image or colour source reports for its settings
    local function source_size(id, vals)
        if id == "image_source" then return png_size(vals.file or "") end
        if id == "color_source" or id == "color_source_v3" then return vals.width or 0, vals.height or 0 end
        return 0, 0
    end
    function obs.obs_source_create_private(id, name, settings)
        if world.unavailable_ids[id] then return nil end
        local src = { id = id, name = name, refs = 1, private = true, filters = {}, handler = {},
            settings = { vals = {}, defs = {} } }
        if settings then copy_into(src.settings.vals, settings.vals) end
        if FILTER_IDS[id] then
            src.kind = "filter"
            src.settings = settings
        else
            src.kind = "source"
            src.base_w, src.base_h = 0, 0
            if id == "image_source" then src.base_w, src.base_h = png_size(src.settings.vals.file or "") end
            src.volume, src.muted, src.monitoring, src.mixers = 1, false, 0, 0
        end
        world.private[#world.private + 1] = src
        return src
    end
    function obs.obs_source_filter_add(s, f) s.filters[#s.filters + 1] = f end
    function obs.obs_source_filter_remove(s, f)
        for i, x in ipairs(s.filters) do
            if x == f then table.remove(s.filters, i) return end
        end
        error("filter_remove: filter not attached")
    end
    function obs.obs_source_get_filter_by_name(s, name)
        for _, f in ipairs(s.filters) do
            if f.name == name then f.refs = f.refs + 1; return f end
        end
        return nil
    end
    function obs.obs_source_enum_filters(s)
        local list = {}
        for _, f in ipairs(s.filters) do f.refs = f.refs + 1; list[#list + 1] = f end
        return list
    end
    function obs.obs_source_filter_set_order(s, f, order)
        assert(order == obs.OBS_ORDER_MOVE_BOTTOM)
        for i, x in ipairs(s.filters) do
            if x == f then table.remove(s.filters, i); break end
        end
        s.filters[#s.filters + 1] = f
    end
    function obs.obs_source_update(f, settings)
        world.update_calls = world.update_calls + 1
        f.applied = deep_copy(settings.vals)
        if f.settings ~= settings then copy_into(f.settings.vals, settings.vals) end
        if f.id == "image_source" or f.id == "color_source" or f.id == "color_source_v3" then
            f.base_w, f.base_h = source_size(f.id, f.settings.vals)
        end
    end
    function obs.obs_source_set_enabled(s, v) s.enabled = v end
    function obs.obs_source_enabled(s) return s.enabled ~= false end

    -- public sources: saved with the scene collection, listed by obs_enum_sources. The caller owns the
    -- returned reference; a scene item adds its own. A removed source ends at 0 references.
    function obs.obs_source_create(id, name, settings)
        if world.unavailable_ids[id] then return nil end
        local src = { id = id, name = name, refs = 1, base_refs = 0, kind = "source", filters = {}, handler = {},
            settings = { vals = {}, defs = {} } }
        if settings then copy_into(src.settings.vals, settings.vals) end
        src.base_w, src.base_h = source_size(id, src.settings.vals)
        world.sources[#world.sources + 1] = src
        return src
    end
    -- Removing a source takes it out of every scene (each item drops its reference), and a scene made by
    -- obs_scene_create also drops the reference the frontend holds for it
    function obs.obs_source_remove(s)
        assert(s, "remove of nil source")
        for _, other in ipairs(world.sources) do
            if other.scene and not other.removed then
                local items = {}
                for _, it in ipairs(other.scene.items) do items[#items + 1] = it end
                for _, it in ipairs(items) do
                    if it.source == s then obs.obs_sceneitem_remove(it) end
                end
            end
        end
        if not s.removed then
            s.removed = true
            if s.frontend_ref then s.refs = s.refs - 1 end
        end
    end

    -- audio and media (private sources only in practice)
    function obs.obs_source_set_volume(s, v) s.volume = v end
    function obs.obs_source_set_muted(s, m) s.muted = m end
    function obs.obs_source_set_monitoring_type(s, m) s.monitoring = m end
    function obs.obs_source_set_audio_mixers(s, m) s.mixers = m end
    function obs.obs_source_get_volume(s) return s.volume end
    function obs.obs_source_muted(s) return s.muted end
    function obs.obs_source_get_monitoring_type(s) return s.monitoring end
    function obs.obs_source_media_restart(s)
        world.media_restarts = world.media_restarts + 1
        s.restarts = (s.restarts or 0) + 1
        s.playing = true
    end
    function obs.obs_source_media_get_state(s) return s.playing and obs.OBS_MEDIA_STATE_PLAYING or 0 end

    -- output channels (the channel holds its own reference)
    function obs.obs_set_output_source(ch, s)
        assert(ch >= 0 and ch < 64, "bad output channel")
        local old = world.channels[ch]
        if s then s.refs = s.refs + 1 end
        if old then old.refs = old.refs - 1 end
        world.channels[ch] = s
    end
    function obs.obs_get_output_source(ch)
        local s = world.channels[ch]
        if s then s.refs = s.refs + 1 end
        return s
    end

    -- properties of a source (for the display name lookup)
    function obs.obs_source_properties(s)
        local props = { items = {} }
        local prop_name = s.id == "screen_capture" and "display_uuid" or (s.id == "monitor_capture" and "monitor_id" or "display")
        local p = { name = prop_name, type = "list", items = s.prop_items }
        props.items[1] = p
        return props
    end
    function obs.obs_properties_destroy() end

    ------------------------------------------------------------------ scenes
    function world.add_scene(name, items)
        local src = { id = "scene", name = name, refs = 1, kind = "source", handler = {} }
        src.scene = { source = src, items = items or {} }
        world.sources[#world.sources + 1] = src
        return src
    end
    -- a group: a scene-like source whose items are positioned relative to the group
    function world.add_group(name, w, h)
        local src = world.add_scene(name)
        src.id = "group"
        src.scene.is_group = true
        src.base_w, src.base_h = w or 0, h or 0
        return src
    end
    function world.add_item(scene_src, source)
        local item = {
            source = source, refs = 1,
            info = { pos = { x = 0, y = 0 }, rot = 0, scale = { x = 1, y = 1 }, alignment = 5,
                bounds_type = 0, bounds_alignment = 0, bounds = { x = 0, y = 0 } },
            crop = { left = 0, top = 0, right = 0, bottom = 0 },
            id = world.next_item_id, scene = scene_src.scene, visible = true, locked = false,
        }
        world.next_item_id = world.next_item_id + 1
        table.insert(scene_src.scene.items, item)
        return item
    end
    function obs.obs_scene_from_source(s) return s.scene end
    function obs.obs_group_from_source(s) return s.scene end
    function obs.obs_scene_get_source(scene) return scene.source end
    function obs.obs_scene_find_source(scene, name)
        for _, it in ipairs(scene.items) do
            if it.source.name == name then return it end
        end
        return nil
    end
    function obs.obs_scene_enum_items(scene) return scene.items end
    function obs.obs_sceneitem_get_source(it) return it.source end
    function obs.obs_sceneitem_addref(it) it.refs = it.refs + 1 end
    function obs.obs_sceneitem_release(it)
        assert(it, "release of nil sceneitem")
        it.refs = it.refs - 1
        if it.refs == 0 and it.owns_source then it.source.refs = it.source.refs - 1 end
    end

    -- scenes created by the script and items added to scenes (obs_scene_add returns a borrowed item)
    function obs.obs_scene_create_private(name)
        local src = { id = "scene", name = name, refs = 1, kind = "source", handler = {}, private = true, filters = {} }
        src.scene = { source = src, items = {} }
        world.private[#world.private + 1] = src
        return src.scene
    end
    -- a public scene (saved, listed in the Scenes dock): one reference for the frontend, one returned
    function obs.obs_scene_create(name)
        if world.unavailable_ids.scene then return nil end
        local src = { id = "scene", name = name, refs = 2, frontend_ref = true, kind = "source", handler = {},
            filters = {}, settings = { vals = {}, defs = {} } }
        src.scene = { source = src, items = {} }
        world.sources[#world.sources + 1] = src
        return src.scene
    end
    function obs.obs_scene_release(scene) assert(scene, "release of nil scene"); scene.source.refs = scene.source.refs - 1 end
    function obs.obs_scene_add(scene, source)
        assert(source, "obs_scene_add of nil source")
        local item = {
            source = source, refs = 1, owns_source = true, id = world.next_item_id, scene = scene,
            visible = true, locked = false,
            info = { pos = { x = 0, y = 0 }, rot = 0, scale = { x = 1, y = 1 }, alignment = 5,
                bounds_type = 0, bounds_alignment = 0, bounds = { x = 0, y = 0 } },
            crop = { left = 0, top = 0, right = 0, bottom = 0 },
        }
        world.next_item_id = world.next_item_id + 1
        source.refs = source.refs + 1
        table.insert(scene.items, item)
        return item
    end
    function obs.obs_sceneitem_remove(it)
        assert(it.scene, "obs_sceneitem_remove: item is not in a scene")
        for i, x in ipairs(it.scene.items) do
            if x == it then
                table.remove(it.scene.items, i)
                it.scene, it.removed = nil, true
                obs.obs_sceneitem_release(it) -- the scene's own reference
                return
            end
        end
        error("obs_sceneitem_remove: item is not in its scene")
    end
    function obs.obs_sceneitem_get_scene(it) return it.scene end
    function obs.obs_scene_is_group(scene) return scene.is_group == true end
    function obs.obs_sceneitem_set_locked(it, v) it.locked = v end
    function obs.obs_sceneitem_set_visible(it, v) it.visible = v end
    function obs.obs_sceneitem_locked(it) return it.locked end
    function obs.obs_sceneitem_visible(it) return it.visible end
    function obs.obs_sceneitem_get_id(it) return it.id end
    function obs.obs_scene_find_sceneitem_by_id(scene, id)
        for _, it in ipairs(scene.items) do
            if it.id == id then return it end
        end
        return nil
    end
    function obs.obs_sceneitem_set_order_position(it, pos)
        assert(it.scene, "set_order_position: item is not in a scene")
        for i, x in ipairs(it.scene.items) do
            if x == it then table.remove(it.scene.items, i); break end
        end
        table.insert(it.scene.items, math.max(0, math.min(#it.scene.items, pos)) + 1, it)
    end

    function obs.obs_transform_info()
        return { pos = { x = 0, y = 0 }, rot = 0, scale = { x = 1, y = 1 }, alignment = 0,
            bounds_type = 0, bounds_alignment = 0, bounds = { x = 0, y = 0 } }
    end
    function obs.obs_sceneitem_crop() return { left = 0, top = 0, right = 0, bottom = 0 } end
    function obs.obs_sceneitem_get_info2(it, info) copy_into(info, it.info) end
    function obs.obs_sceneitem_set_info2(it, info) copy_into(it.info, info) end
    function obs.obs_sceneitem_get_crop(it, crop) copy_into(crop, it.crop) end
    function obs.obs_sceneitem_set_crop(it, crop) copy_into(it.crop, crop) end

    function obs.obs_video_info() return { base_width = 0, base_height = 0 } end
    function obs.obs_get_video_info(v) v.base_width, v.base_height = world.canvas.w, world.canvas.h; return true end

    ------------------------------------------------------------------ properties UI
    function obs.obs_properties_create() return { items = {} } end
    local function add(props, name, kind, extra)
        local p = { name = name, type = kind, visible = true }
        for k, v in pairs(extra or {}) do p[k] = v end
        props.items[#props.items + 1] = p
        return p
    end
    function obs.obs_properties_add_list(props, name) return add(props, name, "list", { items = {} }) end
    function obs.obs_properties_add_bool(props, name) return add(props, name, "bool") end
    function obs.obs_properties_add_int(props, name) return add(props, name, "int") end
    function obs.obs_properties_add_float(props, name) return add(props, name, "float") end
    function obs.obs_properties_add_int_slider(props, name) return add(props, name, "int_slider") end
    function obs.obs_properties_add_float_slider(props, name) return add(props, name, "float_slider") end
    function obs.obs_properties_add_text(props, name) return add(props, name, "text") end
    function obs.obs_properties_add_button(props, name, _, cb) return add(props, name, "button", { cb = cb }) end
    function obs.obs_properties_add_path(props, name, _, kind, filter)
        return add(props, name, "path", { path_type = kind, filter = filter })
    end
    function obs.obs_properties_add_color(props, name) return add(props, name, "color") end
    function obs.obs_properties_add_group(props, name, _, _, children)
        return add(props, name, "group", { children = children })
    end
    local function find(props, name)
        for _, p in ipairs(props.items) do
            if p.name == name then return p end
            if p.children then
                local f = find(p.children, name)
                if f then return f end
            end
        end
    end
    function obs.obs_properties_get(props, name) return find(props, name) end
    world.find_property = find
    function obs.obs_property_set_long_description() end
    function obs.obs_property_set_visible(p, v) p.visible = v end
    function obs.obs_property_set_modified_callback(p, cb) p.modified = cb end
    function obs.obs_property_list_clear(p) p.items = {} end
    function obs.obs_property_list_add_string(p, name, value) p.items[#p.items + 1] = { name = name, value = value } end
    function obs.obs_property_list_item_count(p) return #p.items end
    function obs.obs_property_list_item_name(p, i) return p.items[i + 1].name end
    function obs.obs_property_list_item_string(p, i) return p.items[i + 1].value end
    function obs.obs_property_list_item_int(p, i) return p.items[i + 1].value end

    ------------------------------------------------------------------ leak report
    -- Anything still referenced after unload (the scene source is owned by the test). A live public source
    -- holds its own reference (the test or the frontend owns it; a source made by obs_source_create has
    -- none) plus one per scene item that references it, a removed source none.
    -- opts.allow_filters = { [name] = true } lists filters that may stay attached to public sources
    -- (the studio's mask filter stays with its scene by design).
    function world.leaks(opts)
        opts = opts or {}
        local allow = opts.allow_filters or {}
        local out = {}
        local held = {} -- source -> number of items in live public scenes that hold a reference to it
        for _, s in ipairs(world.sources) do
            if s.scene and not s.removed then
                for _, it in ipairs(s.scene.items) do
                    if it.owns_source then held[it.source] = (held[it.source] or 0) + 1 end
                end
            end
        end
        local function check_scene(name, scene)
            for _, it in ipairs(scene.items) do
                if it.refs ~= 1 then out[#out + 1] = string.format("item %s in %s refs=%d", it.source.name, name, it.refs) end
            end
        end
        for _, s in ipairs(world.sources) do
            if s.removed then
                if s.refs ~= 0 then out[#out + 1] = string.format("removed source %s refs=%d", s.name, s.refs) end
            else
                local want = (s.base_refs or 1) + (held[s] or 0)
                if s.refs ~= want then out[#out + 1] = string.format("source %s refs=%d, expected %d", s.name, s.refs, want) end
                for _, f in ipairs(s.filters or {}) do
                    if not allow[f.name] then out[#out + 1] = "filter still attached: " .. f.name end
                end
                if s.scene then check_scene(s.name, s.scene) end
            end
        end
        for _, s in ipairs(world.private) do
            if s.refs ~= 0 then out[#out + 1] = string.format("private %s refs=%d", s.name, s.refs) end
            for _, f in ipairs(s.filters or {}) do out[#out + 1] = "filter still attached to private: " .. f.name end
            if s.scene then
                for _, it in ipairs(s.scene.items) do out[#out + 1] = "item left in private scene: " .. it.source.name end
            end
        end
        for ch, s in pairs(world.channels) do out[#out + 1] = string.format("output channel %d still holds %s", ch, s.name) end
        return out
    end

    -- Catch use of API names the stub (and so this test) does not know about
    setmetatable(obs, { __index = function(_, k) error("stub obslua has no '" .. tostring(k) .. "'", 2) end })
    return obs, world
end

return M
