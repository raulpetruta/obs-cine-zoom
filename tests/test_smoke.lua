-- Smoke test: build the bundle, load it against the stub obslua under a STRICT global table
-- (any read of an undefined global or write of a non-script_* global is an error), then drive
-- it like OBS would: defaults -> load -> update -> properties -> Diagnose -> ticks -> unload.
local bundle = require("tools_bundle")
local stub = require("stub_obslua")

local DT = 1 / 60

-- Remove everything a previous run left behind so each scenario starts clean
local function clean_env()
    for k in pairs(package.loaded) do
        if k:match("^cinezoom") then package.loaded[k] = nil end
    end
    for k in pairs(package.preload) do
        if k:match("^cinezoom") then package.preload[k] = nil end
    end
    for _, k in ipairs({ "script_description", "script_defaults", "script_properties", "script_load",
        "script_update", "script_tick", "script_save", "script_unload", "obslua" }) do
        rawset(_G, k, nil)
    end
    setmetatable(_G, nil)
end

local function strict_env()
    setmetatable(_G, {
        __index = function(_, k) error("read of undefined global '" .. tostring(k) .. "'", 2) end,
        __newindex = function(t, k, v)
            if type(k) == "string" and k:match("^script_") then
                rawset(t, k, v)
            else
                error("global leaked: '" .. tostring(k) .. "'", 2)
            end
        end,
    })
end

local function load_bundle(root, obs)
    local text = bundle.build(root)
    local chunk = assert(loadstring(text, "=cinezoom.lua"))
    rawset(_G, "obslua", obs)
    strict_env()
    chunk()
end

-- A backend that behaves like macOS with one Retina display, driven by the test
local function fake_backend()
    local b = { name = "fake-mac", ok = true, symbols = { CGEventCreate = true, CGDisplayBounds = true },
        gx = 756, gy = 491, left = false, clicks = 100, keys = 7, closed = false }
    function b.mouse() return b.gx, b.gy end
    function b.displays()
        return { { id = 1, x = 0, y = 0, w = 1512, h = 982, px_w = 3024, px_h = 1964, uuid = "AAAA-BBBB", main = true } }
    end
    function b.buttons() return b.left, b.clicks end
    function b.key_activity() return b.keys end
    function b.close() b.closed = true end
    return b
end

local function ticks(n)
    for _ = 1, n do script_tick(DT) end
end

local function last_applied(filter)
    return filter.applied
end

-- script_tick catches its own errors and logs them, so a clean run must have none
local function assert_no_tick_errors(t, world)
    for _, l in ipairs(world.logs) do
        if l.msg:find("Tick failed", 1, true) or l.msg:find("Unload step", 1, true) then
            error("unexpected failure logged: " .. l.msg, 0)
        end
    end
end

local function logs_text(world)
    local parts = {}
    for _, l in ipairs(world.logs) do parts[#parts + 1] = l.msg end
    return table.concat(parts, "\n")
end

return function(t)
    local root = t.root

    t.test("full lifecycle on a Retina display with a transform crop", function()
        clean_env()
        local obs, world = stub.new()
        local data = obs.obs_data_create()
        local ok, err = pcall(function()
            -- scene with a ScreenCaptureKit source whose size is 0 until its first frame
            local display = world.add_source({ id = "screen_capture", name = "Display", base_w = 0, base_h = 0,
                settings = { display_uuid = "aaaa-bbbb", type = 0 },
                prop_items = { { name = "Built-in Retina Display", value = "AAAA-BBBB" } } })
            local scene = world.add_scene("Scene")
            local item = world.add_item(scene, display)
            item.crop.left = 200 -- user's transform crop, in source pixels
            world.scene_source = scene
            local baseline_data = world.data_live

            load_bundle(root, obs)
            require("cinezoom.platform").set_override(fake_backend(), "OSX")
            local backend = require("cinezoom.platform").get()

            script_defaults(data)
            t.eq(type(script_description()), "string")
            script_load(data)
            data.vals.source = "Display"
            data.vals.follow = true
            script_update(data)

            -- size still 0: attached but not set up, no crop filter yet
            ticks(3)
            t.eq(#display.filters, 0, "no filter before the size is known")

            -- the first frame arrives
            display.base_w, display.base_h = 3024, 1964
            ticks(2)
            t.eq(#display.filters, 2, "temp conversion filter + zoom filter")
            local zoom_filter
            for _, f in ipairs(display.filters) do
                if f.name == "cinezoom-crop" then zoom_filter = f end
            end
            t.truthy(zoom_filter, "zoom crop filter exists")
            t.eq(display.filters[#display.filters], zoom_filter, "zoom filter is last in the chain")
            t.eq(item.crop.left, 0, "transform crop was cleared")
            t.eq(item.info.bounds_type, obs.OBS_BOUNDS_SCALE_INNER, "converted to a bounding box")
            t.eq(zoom_filter.applied.cx, 2824, "camera is the cropped picture")
            t.eq(zoom_filter.applied.cy, 1964)
            t.eq(zoom_filter.applied.left, 0)

            -- zoom in with the mouse at (756, 491) points = (1512, 982) px = (1312, 982) camera px
            world.press("cinezoom.toggle_zoom")
            ticks(240)
            local a = zoom_filter.applied
            t.near(a.cx, 1412, 1, "zoomed 2x")
            t.near(a.left + a.cx / 2, 1312, 2, "view centered on the mouse (crop subtracted AFTER scaling)")
            t.near(a.top + a.cy / 2, 982, 2)

            -- follow: move the mouse right, the view must follow
            backend.gx = 1100
            ticks(240)
            a = zoom_filter.applied
            t.truthy(a.left + a.cx / 2 > 1500, "view followed the mouse")

            -- zoom out returns exactly to the full picture
            world.press("cinezoom.toggle_zoom")
            ticks(600)
            a = zoom_filter.applied
            t.eq(a.left, 0); t.eq(a.top, 0); t.eq(a.cx, 2824); t.eq(a.cy, 1964)

            -- auto-zoom: a click inside zooms in, idle zooms out again
            data.vals.auto_enabled = true
            script_update(data)
            backend.gx, backend.gy = 400, 300
            backend.clicks = backend.clicks + 1
            ticks(60)
            t.truthy(zoom_filter.applied.cx < 2824, "click zoomed in")
            ticks(60 * 6)
            t.eq(zoom_filter.applied.cx, 2824, "idle zoomed out")

            -- properties, buttons and Diagnose
            local props = script_properties()
            t.truthy(world.find_property(props, "source"))
            t.truthy(world.find_property(props, "diagnose_button"))
            local list = world.find_property(props, "source")
            t.eq(list.items[1].value, "cinezoom-none")
            t.eq(list.items[2].value, "Display")
            world.find_property(props, "refresh").cb(props, nil)
            world.find_property(props, "help_button").cb(props, nil)
            world.find_property(props, "motion_preset").modified(props, nil, data)
            world.find_property(props, "diagnose_button").cb(props, nil)
            ticks(60 * 6)
            local text = logs_text(world)
            for _, section in ipairs({ "== Environment ==", "== Backend ==", "== Source ==", "== Displays ==",
                "== Live ==", "Probe finished", "matched: 1512.0x982.0", "base size: 3024x1964" }) do
                t.truthy(text:find(section, 1, true), "Diagnose output has '" .. section .. "'")
            end

            -- hotkeys persist
            script_save(data)
            t.truthy(data.vals["cinezoom.hotkey.zoom"])

            -- unload restores everything and releases every reference
            script_unload()
            t.eq(#display.filters, 0, "filters removed")
            t.eq(item.crop.left, 200, "transform crop restored")
            t.eq(item.info.bounds_type, obs.OBS_BOUNDS_NONE, "transform restored")
            t.eq(next(world.hotkeys), nil, "hotkeys unregistered by id")
            t.eq(next(world.frontend_callbacks), nil, "frontend callback removed")
            t.eq(world.signal_connections, 0)
            t.truthy(backend.closed, "backend closed")
            local leaks = world.leaks()
            t.eq(#leaks, 0, table.concat(leaks, "; "))
            t.eq(world.data_live, baseline_data, "obs_data objects released")
            -- ticks after unload do nothing and do not throw
            ticks(3)
            script_unload() -- twice is harmless
            assert_no_tick_errors(t, world)
        end)
        clean_env()
        if not ok then error(err, 0) end
    end)

    t.test("source without a display match warns (always) and does not crash", function()
        clean_env()
        local obs, world = stub.new()
        local data = obs.obs_data_create()
        local ok, err = pcall(function()
            local display = world.add_source({ id = "screen_capture", name = "Display", base_w = 3024, base_h = 1964,
                settings = { display_uuid = "no-such-uuid", type = 0 },
                prop_items = { { name = "Built-in Retina Display", value = "no-such-uuid" } } })
            local scene = world.add_scene("Scene")
            world.add_item(scene, display)
            world.scene_source = scene
            load_bundle(root, obs)
            require("cinezoom.platform").set_override(fake_backend(), "OSX")
            script_defaults(data)
            script_load(data)
            data.vals.source = "Display"
            script_update(data)
            ticks(30)
            world.press("cinezoom.toggle_zoom") -- no display, but zooming must still not throw
            ticks(30)
            local warned = false
            for _, l in ipairs(world.logs) do
                if l.level == obs.OBS_LOG_WARNING and l.msg:find("Could not work out which display", 1, true) then
                    warned = true
                end
            end
            t.truthy(warned, "WARN printed with debug logging off")
            script_unload()
            assert_no_tick_errors(t, world)
            t.eq(#world.leaks(), 0)
        end)
        clean_env()
        if not ok then error(err, 0) end
    end)

    t.test("OBS finishing loading after the script (first start) attaches the source", function()
        clean_env()
        local obs, world = stub.new()
        local data = obs.obs_data_create()
        local ok, err = pcall(function()
            local display = world.add_source({ id = "monitor_capture", name = "Display", base_w = 1920, base_h = 1080,
                prop_items = { { name = "DELL: 1920x1080 @ 0,0 (Primary Monitor)", value = "m1" } },
                settings = { monitor_id = "m1" } })
            local scene = world.add_scene("Scene")
            world.add_item(scene, display)
            -- no current scene yet: OBS has not finished loading
            load_bundle(root, obs)
            require("cinezoom.platform").set_override(fake_backend(), "Windows")
            script_defaults(data)
            script_load(data)
            data.vals.source = "Display"
            script_update(data)
            ticks(5)
            t.eq(#display.filters, 0)
            world.scene_source = scene
            world.fire_event(obs.OBS_FRONTEND_EVENT_FINISHED_LOADING)
            ticks(5)
            t.eq(#display.filters, 1, "crop filter created after loading finished")
            -- scene change releases and re-attaches
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_CHANGED)
            t.eq(#display.filters, 1)
            -- shutdown event unloads
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN)
            t.eq(#display.filters, 0)
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            assert_no_tick_errors(t, world)
        end)
        clean_env()
        if not ok then error(err, 0) end
    end)

    t.test("default backend on this machine (no real display) loads, ticks and unloads", function()
        clean_env()
        local obs, world = stub.new()
        local data = obs.obs_data_create()
        local ok, err = pcall(function()
            local display = world.add_source({ id = "xshm_input", name = "Screen", base_w = 1920, base_h = 1080,
                prop_items = { { name = "Screen 0 (1920x1080 @ 0,0)", value = 0 } }, settings = { screen = 0 } })
            local scene = world.add_scene("Scene")
            world.add_item(scene, display)
            world.scene_source = scene
            load_bundle(root, obs)
            script_defaults(data)
            script_load(data)
            data.vals.source = "Screen"
            script_update(data)
            ticks(120)
            script_properties()
            script_unload()
            assert_no_tick_errors(t, world)
        end)
        clean_env()
        if not ok then error(err, 0) end
    end)

    t.test("old OBS (29.1.2) skips the crashy unload block but does not throw", function()
        clean_env()
        local obs, world = stub.new()
        world.version = "29.1.2"
        local data = obs.obs_data_create()
        local ok, err = pcall(function()
            world.scene_source = world.add_scene("Scene")
            load_bundle(root, obs)
            script_defaults(data)
            script_load(data)
            script_update(data)
            script_unload()
        end)
        clean_env()
        if not ok then error(err, 0) end
    end)

    t.test("the bundle leaks no globals when loaded", function()
        clean_env()
        local obs = stub.new()
        local before = {}
        for k in pairs(_G) do before[k] = true end
        local ok, err = pcall(function() load_bundle(root, obs) end)
        local leaked = {}
        for k in pairs(_G) do
            if not before[k] and not tostring(k):match("^script_") and k ~= "obslua" then leaked[#leaked + 1] = k end
        end
        clean_env()
        if not ok then error(err, 0) end
        t.eq(#leaked, 0, table.concat(leaked, ","))
    end)

    ----------------------------------------------------------------------
    -- click effects
    ----------------------------------------------------------------------
    local function scratch_dir()
        local base = os.tmpname()
        os.remove(base)
        assert(os.execute('mkdir -p "' .. base .. '"') == 0, "cannot create a scratch directory")
        return base
    end

    local function list_dir(dir)
        local out = {}
        local p = io.popen('ls -A "' .. dir .. '"')
        for l in p:lines() do out[#out + 1] = l end
        p:close()
        return out
    end

    local function remove_dir(dir)
        if dir:match("^/") and #dir > 5 then os.execute('rm -rf "' .. dir .. '"') end
    end

    local function find_private(world, name, live)
        local found = nil
        for _, s in ipairs(world.private) do
            if s.name == name and (not live or s.refs > 0) then found = s end
        end
        return found
    end

    -- Run body(obs, world, data) in a fresh environment, always cleaning up
    local function scenario(body)
        clean_env()
        local obs, world = stub.new()
        local data = obs.obs_data_create()
        local dir = scratch_dir()
        local ok, err = pcall(body, obs, world, data, dir)
        clean_env()
        remove_dir(dir)
        if not ok then error(err, 0) end
    end

    -- A Retina display capture in a 1920x1080 bounding box (letterboxed, centered), mouse at (400,300)
    -- points = (800,600) source pixels. In a group the capture sits in a half-size group at (100,50).
    local function fx_world(obs, world, opts)
        opts = opts or {}
        local display = world.add_source({ id = "screen_capture", name = "Display", base_w = 3024, base_h = 1964,
            settings = { display_uuid = "aaaa-bbbb", type = 0 },
            prop_items = { { name = "Built-in Retina Display", value = "AAAA-BBBB" } } })
        local scene = world.add_scene("Scene")
        local item, group_item
        if opts.group then
            local group = world.add_group("Group", 1920, 1080)
            item = world.add_item(group, display)
            group_item = world.add_item(scene, group)
            group_item.info.scale.x, group_item.info.scale.y = 0.5, 0.5
            group_item.info.pos.x, group_item.info.pos.y = 100, 50
        else
            item = world.add_item(scene, display)
        end
        item.info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
        item.info.bounds = { x = 1920, y = 1080 }
        item.info.bounds_alignment = 0
        item.info.alignment = 5
        world.scene_source = scene
        return { display = display, scene = scene, item = item, group_item = group_item }
    end

    local function start(obs, world, data, dir, w, vals)
        load_bundle(t.root, obs)
        require("cinezoom.effects").asset_dir = dir
        local backend = fake_backend()
        backend.gx, backend.gy = 400, 300
        require("cinezoom.platform").set_override(backend, "OSX")
        script_defaults(data)
        script_load(data)
        data.vals.source = "Display"
        for k, v in pairs(vals or {}) do data.vals[k] = v end
        script_update(data)
        ticks(2)
        return backend
    end

    local function click(backend, n)
        backend.clicks = backend.clicks + (n or 1)
        ticks(1)
    end

    local function crop_filter(display)
        for _, f in ipairs(display.filters) do
            if f.name == "cinezoom-crop" then return f end
        end
    end

    -- The canvas point of camera point (ax, ay) for the crop the filter really applies (hand-written math)
    local function expect_canvas(a, ax, ay)
        local s = math.min(1920 / a.cx, 1080 / a.cy)
        local w, h = a.cx * s, a.cy * s
        local ox, oy = (1920 - w) / 2, (1080 - h) / 2
        return ox + (ax - a.left) / a.cx * w, oy + (ay - a.top) / a.cy * h
    end

    local ALL_ON = { fx_sound_enabled = true, fx_ripple_enabled = true }

    t.test("effects off by default: a click creates no sources, channels or items", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local backend = start(obs, world, data, dir, w)
            click(backend, 1)
            ticks(10)
            for _, p in ipairs(world.private) do
                t.eq(p.id, "crop_filter", "only the zoom crop filter exists, found " .. tostring(p.id))
            end
            t.eq(next(world.channels), nil, "no output channel")
            t.eq(#w.scene.scene.items, 1, "scene holds only the capture item")
            t.eq(world.media_restarts, 0)
            t.eq(#list_dir(dir), 0, "no files written")
            local props = script_properties()
            t.eq(world.find_property(props, "fx_sound_enabled").type, "group")
            t.eq(world.find_property(props, "fx_ripple_enabled").type, "group")
            t.truthy(world.find_property(props, "fx_test_button"))
            t.truthy(world.find_property(props, "fx_ripple_color"))
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            assert_no_tick_errors(t, world)
        end)
    end)

    t.test("effects on: full run, placement, zoom, scene changes, unload", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local baseline_data = world.data_live
            local backend = start(obs, world, data, dir, w, ALL_ON)
            local zoom_filter = crop_filter(w.display)
            local items = w.scene.scene.items

            -- setup created the sources but nothing is on screen and nothing clicked yet
            local files = list_dir(dir)
            t.eq(#files, 2, "one sound and one ring file: " .. table.concat(files, ","))
            t.truthy(world.channels[63] and world.channels[62], "two voices on the highest free channels")
            t.eq(world.channels[63].id, "ffmpeg_source")
            t.eq(world.channels[63].muted, true, "muted until the first click (no click at load)")
            t.near(world.channels[63].volume, 0.25, 1e-9, "volume 50% is squared")
            t.eq(world.channels[63].monitoring, obs.OBS_MONITORING_TYPE_NONE)
            t.eq(world.media_restarts, 0)
            t.eq(#items, 1, "no overlay item before a click")

            -- first click at zoom 1
            click(backend)
            t.eq(world.media_restarts, 1, "one sound")
            t.eq(#items, 2, "overlay added")
            t.eq(items[1], w.item, "capture stays at the bottom")
            local overlay_item = items[2]
            t.eq(overlay_item.locked, true)
            t.eq(overlay_item.source.name, "OBSCineZoom click effects")
            t.eq(overlay_item.info.pos.x, 0); t.eq(overlay_item.info.scale.x, 1)
            t.eq(overlay_item.info.bounds_type, obs.OBS_BOUNDS_NONE)
            local overlay = find_private(world, "OBSCineZoom click effects", true).scene
            local ring = overlay.items[1]
            t.eq(ring.visible, true)
            -- hand-computed: letterboxed picture, 800x600 source px
            t.near(ring.info.pos.x, 568.4725, 0.01, "canvas x"); t.near(ring.info.pos.y, 329.9389, 0.01, "canvas y")
            t.eq(ring.info.alignment, 0, "centered on the point")
            t.near(ring.info.scale.x, 72 * 0.25 / 256, 1e-9, "starts at 25% of 72 px")
            local filter = ring.source.filters[1]
            t.eq(filter.id, "color_filter_v2")
            t.near(filter.applied.opacity, 0.85, 1e-9)

            -- a ripple fades while it plays and is hidden when done
            ticks(15)
            t.truthy(filter.applied.opacity < 0.85 and ring.info.scale.x > 72 * 0.25 / 256)
            ticks(25)
            t.eq(ring.visible, false, "hidden after the duration")

            -- zoom in, click again: still on the click, larger with "scale with zoom"
            world.press("cinezoom.toggle_zoom")
            ticks(240)
            click(backend)
            local a = zoom_filter.applied
            local ex, ey = expect_canvas(a, 800, 600)
            ring = overlay.items[2] -- the second slot (the first is free again but the pool takes the first free one)
            for _, it in ipairs(overlay.items) do if it.visible then ring = it end end
            t.eq(ring.visible, true)
            t.near(ring.info.pos.x, ex, 1e-6); t.near(ring.info.pos.y, ey, 1e-6)
            t.near(ring.info.pos.x, 960, 3); t.near(ring.info.pos.y, 540, 3)
            t.near(ring.info.scale.x * 256, 72 * 2 * 0.25, 0.3, "2x zoom doubles the ring")
            t.eq(world.media_restarts, 2)

            -- the view moves while the ripple runs: the ring follows the content
            local before_x = ring.info.pos.x
            backend.gx = 1100
            ticks(8)
            a = zoom_filter.applied
            ex, ey = expect_canvas(a, 800, 600)
            t.near(ring.info.pos.x, ex, 1e-6, "follows the view"); t.near(ring.info.pos.y, ey, 1e-6)
            t.truthy(math.abs(ring.info.pos.x - before_x) > 1, "the view really moved")
            ticks(40)
            t.eq(ring.visible, false)

            -- scene change: the overlay leaves the scene and comes back with the next click
            world.press("cinezoom.toggle_zoom")
            ticks(300)
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_CHANGED)
            t.eq(#items, 1, "overlay removed on scene change")
            backend.gx = 400
            ticks(2)
            click(backend)
            t.eq(#items, 2, "overlay added again")
            t.eq(items[2].locked, true)

            -- the collection changes: our overlay goes away, OBS clears the channels, we put the sound back
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING)
            t.eq(#items, 1, "overlay removed before the collection changes")
            local old_voice = world.channels[63]
            obs.obs_set_output_source(63, nil)
            obs.obs_set_output_source(62, nil)
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED)
            t.eq(world.channels[63], old_voice, "voice back on its channel")
            t.truthy(world.channels[62])
            click(backend)
            t.eq(#items, 2, "overlay works after the change")

            -- Diagnose and the test button
            local props = script_properties()
            world.find_property(props, "diagnose_button").cb(props, nil)
            local before = world.media_restarts
            world.find_property(props, "fx_test_button").cb(props, nil)
            t.eq(world.media_restarts, before + 1, "test button plays")
            local text = logs_text(world)
            for _, needle in ipairs({ "== Click effects ==", "opacity filter: v2", "channel 63", "overlay item: id",
                "last click:", "cross-check:", "Settings > Audio > Advanced", "Test click:" }) do
                t.truthy(text:find(needle, 1, true), "Diagnose/log has '" .. needle .. "'")
            end

            script_unload()
            t.eq(next(world.channels), nil, "channels empty")
            t.eq(#items, 1, "scene holds only the capture item")
            t.eq(items[1], w.item)
            t.eq(#w.display.filters, 0)
            local leaks = world.leaks()
            t.eq(#leaks, 0, table.concat(leaks, "; "))
            for _, p in ipairs(world.private) do t.eq(p.refs, 0, p.name .. " refs") end
            t.eq(world.data_live, baseline_data, "obs_data objects released")
            t.eq(#list_dir(dir), 0, "generated files removed")
            assert_no_tick_errors(t, world)
        end)
    end)

    t.test("effects do not change the zoom values", function()
        local function run(vals, dir_out)
            local trace = {}
            scenario(function(obs, world, data, dir)
                local w = fx_world(obs, world)
                local backend = start(obs, world, data, dir, w, vals)
                local zf = crop_filter(w.display)
                local function rec()
                    local a = zf.applied
                    trace[#trace + 1] = string.format("%d,%d,%d,%d", a.left, a.top, a.cx, a.cy)
                end
                data.vals.auto_enabled = true
                script_update(data)
                for i = 1, 400 do
                    if i == 10 or i == 11 or i == 200 then backend.clicks = backend.clicks + 1 end
                    if i == 100 then backend.gx = 1000 end
                    if i == 150 then world.press("cinezoom.toggle_zoom") end
                    ticks(1)
                    rec()
                end
                script_unload()
            end)
            return table.concat(trace, ";")
        end
        local off, on = run({}), run(ALL_ON)
        t.truthy(#off > 1000)
        t.eq(on, off, "crop values are identical with effects on")
    end)

    t.test("only_inside: a click outside the display plays nothing (unless switched off)", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local backend = start(obs, world, data, dir, w, ALL_ON)
            backend.gx, backend.gy = 2000, 300 -- outside the 1512 point wide display
            ticks(2)
            click(backend)
            t.eq(world.media_restarts, 0, "no sound")
            t.eq(#w.scene.scene.items, 1, "no overlay")
            data.vals.fx_only_inside = false
            script_update(data)
            click(backend)
            t.eq(world.media_restarts, 1, "sound plays when only_inside is off")
            t.eq(#w.scene.scene.items, 1, "but never a ripple outside the display")
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            assert_no_tick_errors(t, world)
        end)
    end)

    t.test("only_zoomed: clicks are ignored until the view is zoomed in", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local backend = start(obs, world, data, dir, w, { fx_sound_enabled = true, fx_only_zoomed = true })
            click(backend)
            t.eq(world.media_restarts, 0)
            world.press("cinezoom.toggle_zoom")
            ticks(5)
            click(backend)
            t.eq(world.media_restarts, 1)
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            assert_no_tick_errors(t, world)
        end)
    end)

    t.test("capture inside a group: the overlay sits above the group item and the ring maps through it", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world, { group = true })
            local backend = start(obs, world, data, dir, w, { fx_ripple_enabled = true })
            local items = w.scene.scene.items
            click(backend)
            t.eq(#items, 2, "overlay added to the scene that holds the group")
            t.eq(items[1], w.group_item)
            t.eq(items[2].source.name, "OBSCineZoom click effects")
            local overlay = find_private(world, "OBSCineZoom click effects", true).scene
            local ring = overlay.items[1]
            -- group-local (568.47, 329.94) -> half size at (100, 50)
            t.near(ring.info.pos.x, 100 + 568.4725 * 0.5, 0.01)
            t.near(ring.info.pos.y, 50 + 329.9389 * 0.5, 0.01)
            t.near(ring.info.scale.x * 256, 72 * 0.5 * 0.25, 1e-6, "ring shrinks with the group")
            script_unload()
            t.eq(#items, 1)
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            assert_no_tick_errors(t, world)
        end)
    end)

    t.test("opacity filter falls back to color_filter, then to none", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            world.unavailable_ids.color_filter_v2 = true
            local backend = start(obs, world, data, dir, w, { fx_ripple_enabled = true })
            click(backend)
            local overlay = find_private(world, "OBSCineZoom click effects", true).scene
            local f = overlay.items[1].source.filters[1]
            t.eq(f.id, "color_filter")
            t.eq(f.applied.opacity, 85, "integer percent")
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
        end)
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            world.unavailable_ids.color_filter_v2 = true
            world.unavailable_ids.color_filter = true
            local backend = start(obs, world, data, dir, w, { fx_ripple_enabled = true })
            click(backend)
            local overlay = find_private(world, "OBSCineZoom click effects", true).scene
            t.eq(#overlay.items[1].source.filters, 0)
            t.truthy(overlay.items[1].visible, "ripple still shows without a fade")
            t.truthy(logs_text(world):find("no opacity filter", 1, true))
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
        end)
    end)

    t.test("an unreadable custom file warns and falls back to the generated one", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local backend = start(obs, world, data, dir, w, { fx_sound_enabled = true,
                fx_sound_file = "/definitely/not/here.wav" })
            local voice = world.channels[63]
            t.truthy(voice, "sound created")
            t.truthy(voice.settings.vals.local_file:find("cinezoom-click-v1.wav", 1, true))
            local n = 0
            for _, l in ipairs(world.logs) do
                if l.level == obs.OBS_LOG_WARNING and l.msg:find("cannot read '/definitely/not/here.wav'", 1, true) then n = n + 1 end
            end
            t.eq(n, 1, "one warning (not one per settings change)")
            -- a readable custom file wins
            local custom = dir .. "/mine.wav"
            local f = assert(io.open(custom, "wb")); f:write("RIFF"); f:close()
            data.vals.fx_sound_file = custom
            script_update(data)
            t.eq(world.channels[63].settings.vals.local_file, custom)
            script_unload()
            t.truthy(io.open(custom, "rb"), "the user's file is never deleted")
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
        end)
    end)

    t.test("an error in the effects never stops the zoom, and turns them off after three", function()
        scenario(function(obs, world, data, dir)
            local w = fx_world(obs, world)
            local backend = start(obs, world, data, dir, w, ALL_ON)
            local zf = crop_filter(w.display)
            local real = obs.obs_sceneitem_get_scene
            obs.obs_sceneitem_get_scene = function() error("boom") end
            world.press("cinezoom.toggle_zoom")
            for _ = 1, 3 do click(backend) end
            obs.obs_sceneitem_get_scene = real
            local text = logs_text(world)
            t.truthy(text:find("Click effects failed three times", 1, true), "ERROR logged")
            t.eq(next(world.channels), nil, "effects torn down")
            ticks(240)
            t.truthy(zf.applied.cx < 3024 - 1000, "zoom kept working")
            click(backend) -- off: nothing happens
            t.eq(world.media_restarts, 3)
            for _, l in ipairs(world.logs) do t.truthy(not l.msg:find("Tick failed", 1, true), l.msg) end
            -- a settings change turns them on again
            script_update(data)
            t.truthy(world.channels[63], "back on after a settings change")
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
        end)
    end)
end
