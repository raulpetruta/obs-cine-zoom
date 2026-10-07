-- Studio scene builder end to end: build the bundle, load it against the stub obslua under a strict global
-- table, then press the Apply / Remove buttons and watch the scenes, items, filters, files and references.
local bundle = require("tools_bundle")
local stub = require("stub_obslua")
local layout = require("cinezoom.studio.layout")

local DT = 1 / 60
local SCENE, FRAME = "OBSCineZoom Studio", "OBSCineZoom Studio Frame"
local BG, SHADOW, MASK = "OBSCineZoom Background", "OBSCineZoom Shadow", "OBSCineZoom Rounded Corners"

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

local function fake_backend()
    local b = { name = "fake-mac", ok = true, symbols = {}, gx = 400, gy = 300, left = false, clicks = 100, keys = 7 }
    function b.mouse() return b.gx, b.gy end
    function b.displays()
        return { { id = 1, x = 0, y = 0, w = 1512, h = 982, px_w = 3024, px_h = 1964, uuid = "AAAA-BBBB", main = true } }
    end
    function b.buttons() return b.left, b.clicks end
    function b.key_activity() return b.keys end
    function b.close() end
    return b
end

local function ticks(n)
    for _ = 1, n do script_tick(DT) end
end

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

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function logs_text(world)
    local parts = {}
    for _, l in ipairs(world.logs) do parts[#parts + 1] = l.msg end
    return table.concat(parts, "\n")
end

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = deep_copy(x) end
    return c
end

local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- A live (not removed) public source by name
local function find(world, name)
    for _, s in ipairs(world.sources) do
        if s.name == name and not s.removed then return s end
    end
end

local function crop_filter(display)
    for _, f in ipairs(display.filters) do
        if f.name == "cinezoom-crop" then return f end
    end
end

local function press(world, name)
    local props = script_properties()
    world.find_property(props, name).cb(props, nil)
end

local function item_named(scene_src, name)
    for _, it in ipairs(scene_src.scene.items) do
        if it.source.name == name then return it end
    end
end

local function studio_files(dir)
    local n = 0
    for _, f in ipairs(list_dir(dir)) do
        if f:match("^obscinezoom%-studio%-") then n = n + 1 end
    end
    return n
end

local ALLOW = { allow_filters = { [MASK] = true } }

return function(t)
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

    -- "Desktop" scene: a Retina display capture in a 1920x1080 bounding box, plus a label item
    local function desktop(obs, world, size_known)
        local display = world.add_source({ id = "screen_capture", name = "Display",
            base_w = size_known == false and 0 or 3024, base_h = size_known == false and 0 or 1964,
            settings = { display_uuid = "aaaa-bbbb", type = 0 },
            prop_items = { { name = "Built-in Retina Display", value = "AAAA-BBBB" } } })
        local label = world.add_source({ id = "text_ft2_source_v2", name = "Label", base_w = 200, base_h = 50 })
        local scene = world.add_scene("Desktop")
        local item = world.add_item(scene, display)
        item.info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
        item.info.bounds = { x = 1920, y = 1080 }
        item.info.bounds_alignment = 0
        item.info.alignment = 5
        local label_item = world.add_item(scene, label)
        label_item.info.pos = { x = 40, y = 30 }
        world.scene_source = scene
        return { display = display, label = label, scene = scene, item = item, label_item = label_item }
    end

    local function start(obs, world, data, dir, vals)
        load_bundle(t.root, obs)
        require("cinezoom.effects").asset_dir = dir
        require("cinezoom.studio").asset_dir = dir
        local backend = fake_backend()
        require("cinezoom.platform").set_override(backend, "OSX")
        script_defaults(data)
        script_load(data)
        data.vals.source = "Display"
        for k, v in pairs(vals or {}) do data.vals[k] = v end
        script_update(data)
        ticks(2)
        return backend
    end

    local function snapshot(w)
        return { deep_copy(w.item.info), deep_copy(w.item.crop), w.item.locked, w.item.visible,
            deep_copy(w.label_item.info), w.label_item.locked, w.label_item.visible, #w.scene.scene.items }
    end

    -- The look the defaults give for a 3024x1964 capture on a 1920x1080 canvas
    local function expected(pad)
        local content = layout.frame_content(1920, 1080, 3024, 1964)
        local target = layout.target_rect(1920, 1080, 3024, 1964, pad or 6)
        return content, target, layout.frame_transform(content, target)
    end

    local function no_failures(world)
        local text = logs_text(world)
        for _, bad in ipairs({ "Tick failed", "Unload step", "Studio look error", "failed:", "could not" }) do
            if text:find(bad, 1, true) then error("unexpected log: " .. bad .. "\n" .. text, 0) end
        end
    end

    t.test("studio: nothing is created or written until Apply is pressed", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local before = #world.sources
            local backend = start(obs, world, data, dir)
            backend.clicks = backend.clicks + 1
            ticks(30)
            data.vals.studio_padding = 10
            data.vals.studio_radius = 30
            script_update(data)
            ticks(60)
            t.eq(#world.sources, before, "no new public source or scene")
            for _, p in ipairs(world.private) do
                t.eq(p.id, "crop_filter", "only the zoom crop filter exists, found " .. tostring(p.id))
            end
            t.eq(#list_dir(dir), 0, "no files written")
            t.eq(world.scene_switches, nil, "no scene change")
            local props = script_properties()
            for _, name in ipairs({ "grp_studio", "studio_bg_type", "studio_apply_button", "studio_remove_button",
                "studio_padding", "studio_radius", "studio_shadow_opacity" }) do
                t.truthy(world.find_property(props, name), "property " .. name)
            end
            world.find_property(props, "diagnose_button").cb(props, nil)
            t.truthy(logs_text(world):find("studio look is off", 1, true), "Diagnose says it is off")
            t.eq(#list_dir(dir), 0, "Diagnose does not probe a folder while the studio is off")
            script_unload()
            t.eq(#world.leaks(), 0, table.concat(world.leaks(), "; "))
            t.eq(#w.scene.scene.items, 2)
            no_failures(world)
        end)
    end)

    t.test("studio: Apply builds both scenes, the mask and the images, and switches to the Studio scene", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local before = snapshot(w)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")

            local studio, frame = find(world, SCENE), find(world, FRAME)
            t.truthy(studio and frame, "both scenes exist")
            t.eq(#studio.scene.items, 3)
            local names = {}
            for i, it in ipairs(studio.scene.items) do
                names[i] = it.source.name
                t.eq(it.locked, true, it.source.name .. " is locked")
            end
            t.eq(table.concat(names, "|"), BG .. "|" .. SHADOW .. "|" .. FRAME, "order bottom to top")
            t.eq(studio.scene.items[1].source.id, "image_source", "gradient background")
            t.eq(studio.scene.items[2].source.id, "image_source")

            -- the frame scene holds the capture, fitted into the canvas
            t.eq(#frame.scene.items, 1)
            local cap = frame.scene.items[1]
            t.eq(cap.source, w.display)
            t.eq(cap.info.bounds_type, obs.OBS_BOUNDS_SCALE_INNER)
            t.eq(cap.info.bounds.x, 1920); t.eq(cap.info.bounds.y, 1080)
            t.eq(cap.info.alignment, 5); t.eq(cap.info.bounds_alignment, 0)
            t.eq(cap.info.pos.x, 0); t.eq(cap.info.scale.x, 1)
            t.eq(cap.locked, true)

            -- frame item: scaled into the padded target
            local _, target, tf = expected()
            local fi = studio.scene.items[3]
            t.eq(fi.info.bounds_type, obs.OBS_BOUNDS_NONE)
            t.eq(fi.info.alignment, 5)
            t.near(fi.info.scale.x, tf.scale, 1e-9); t.near(fi.info.scale.y, tf.scale, 1e-9)
            t.near(fi.info.pos.x, tf.pos_x, 1e-9); t.near(fi.info.pos.y, tf.pos_y, 1e-9)
            t.near(tf.scale, 0.88, 1e-9, "6% padding on 1080 leaves 88%")

            -- shadow item
            local si_ = studio.scene.items[2]
            t.eq(si_.info.bounds_type, obs.OBS_BOUNDS_STRETCH)
            t.near(si_.info.bounds.x, target.w + 80, 1e-6)
            t.near(si_.info.pos.x, target.x - 40, 1e-6)
            t.near(si_.info.pos.y, target.y - 40 + 12, 1e-6, "offset 12 down")
            t.eq(si_.visible, true)
            t.eq(si_.info.bounds_type, obs.OBS_BOUNDS_STRETCH)

            -- mask filter on the frame scene
            t.eq(#frame.filters, 1)
            local mf = frame.filters[1]
            t.eq(mf.name, MASK); t.eq(mf.id, "mask_filter_v2"); t.eq(mf.enabled ~= false, true)
            local v = mf.settings.vals
            t.eq(v.type, "mask_alpha_filter.effect"); t.eq(v.stretch, true)
            t.eq(v.color, 4294967295); t.eq(v.opacity, 1.0)
            t.truthy(exists(v.image_path), "mask file exists")
            t.eq(v.image_path:match("[^/]+$"):match("^obscinezoom%-studio%-mask%-v1%-%x+%.png$") ~= nil, true)

            -- images, current scene, the capture is found through the nested frame scene
            t.eq(studio_files(dir), 3, "gradient, mask and shadow")
            t.eq(world.scene_source, studio)
            t.eq(studio.scene.items[1].source.settings.vals.file:find(dir, 1, true), 1, "gradient in the asset folder")
            local props = script_properties()
            world.find_property(props, "diagnose_button").cb(props, nil)
            local text = logs_text(world)
            for _, needle in ipairs({ "== Studio ==", "applied: true", "zoom item is in the frame scene: true",
                "current scene is the Studio scene: true", "background source id: image_source", "mask filter: id mask_filter_v2",
                "capture filters, in order: cinezoom-crop", "source size used: 3024x1964 (measured)",
                "chosen via test hook" }) do
                t.truthy(text:find(needle, 1, true), "Diagnose has '" .. needle .. "'")
            end

            -- the user's scene is exactly as it was (Apply released the zoom item first)
            t.truthy(deep_eq(snapshot(w), before), "Desktop scene untouched")
            no_failures(world)
            script_unload()
        end)
    end)

    t.test("studio: zoom works in the Studio scene and leaves the layout and the capture item alone", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local backend = start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            local cap = frame.scene.items[1]
            local cap_before, frame_before = deep_copy(cap.info), deep_copy(studio.scene.items[3].info)
            local mask_before = frame.filters[1].settings.vals.image_path

            t.eq(#w.display.filters, 1, "only the zoom crop filter on the capture")
            local zf = crop_filter(w.display)
            t.truthy(zf, "zoom crop filter")
            t.eq(zf.applied.cx, 3024)
            world.press("cinezoom.toggle_zoom")
            ticks(240)
            t.near(zf.applied.cx, 1512, 2, "zoomed 2x")
            t.eq(#w.display.filters, 1)
            t.truthy(deep_eq(cap.info, cap_before), "capture item transform unchanged by zoom")
            t.truthy(deep_eq(studio.scene.items[3].info, frame_before), "frame item unchanged by zoom")
            t.eq(frame.filters[1].settings.vals.image_path, mask_before, "mask unchanged by zoom")
            backend.gx = 1000
            ticks(60)
            t.truthy(zf.applied.left > 0, "follow works")
            no_failures(world)
            script_unload()
        end)
    end)

    t.test("studio: a ripple lands in the frame scene and maps through the frame transform", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local backend = start(obs, world, data, dir, { fx_ripple_enabled = true })
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            t.eq(#frame.scene.items, 1)
            backend.clicks = backend.clicks + 1
            ticks(1)
            t.eq(#frame.scene.items, 2, "overlay is in the frame scene")
            t.eq(frame.scene.items[2].source.name, "OBSCineZoom click effects")
            t.eq(#studio.scene.items, 3, "and not in the Studio scene")
            t.eq(#w.scene.scene.items, 2, "nor in the Desktop scene")

            -- mouse at (400,300) points = (800,600) source pixels
            local overlay
            for _, p in ipairs(world.private) do
                if p.name == "OBSCineZoom click effects" and p.refs > 0 then overlay = p end
            end
            local ring
            for _, it in ipairs(overlay.scene.items) do if it.visible then ring = it end end
            t.truthy(ring, "a ring is visible")
            local content, target, tf = expected()
            -- in the frame scene: the capture, fitted
            t.near(ring.info.pos.x, content.x + 800 / 3024 * content.w, 1e-6)
            t.near(ring.info.pos.y, content.y + 600 / 1964 * content.h, 1e-6)
            -- on the canvas: through the frame item, the same point of the padded target
            local cx, cy = layout.canvas_point({ x = ring.info.pos.x, y = ring.info.pos.y }, tf)
            t.near(cx, target.x + 800 / 3024 * target.w, 1e-6)
            t.near(cy, target.y + 600 / 1964 * target.h, 1e-6)
            no_failures(world)
            script_unload()
        end)
    end)

    t.test("studio: changing a setting updates the frame, mask and files after the debounce, nothing else", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            local cap = frame.scene.items[1]
            local cap_before = deep_copy(cap.info)
            local mf = frame.filters[1]
            local old_mask = mf.settings.vals.image_path
            local fi = studio.scene.items[3]
            local old_scale = fi.info.scale.x

            data.vals.studio_padding = 12
            script_update(data)
            ticks(10) -- 0.17 s: still waiting
            t.near(fi.info.scale.x, old_scale, 1e-12, "debounced")
            ticks(20)
            local _, target, tf = expected(12)
            t.near(fi.info.scale.x, tf.scale, 1e-9, "new scale")
            t.near(fi.info.pos.x, tf.pos_x, 1e-9)
            t.truthy(fi.info.scale.x < old_scale)
            local new_mask = mf.settings.vals.image_path
            t.truthy(new_mask ~= old_mask, "mask path changed")
            t.truthy(exists(new_mask), "new mask exists")
            t.eq(exists(old_mask), false, "old mask file deleted")
            t.eq(studio_files(dir), 3, "still gradient, mask and shadow")
            t.truthy(deep_eq(cap.info, cap_before), "capture item transform unchanged")
            t.truthy(crop_filter(w.display), "zoom still attached")

            -- radius 0 turns the mask off and drops its file
            data.vals.studio_radius = 0
            script_update(data)
            ticks(25)
            t.eq(mf.enabled, false)
            t.eq(studio_files(dir), 2)
            data.vals.studio_radius = 25
            script_update(data)
            ticks(25)
            t.eq(mf.enabled, true)
            t.truthy(exists(mf.settings.vals.image_path))
            t.eq(studio_files(dir), 3)

            -- shadow off hides the item and drops the image
            data.vals.studio_shadow_enabled = false
            script_update(data)
            ticks(25)
            t.eq(studio.scene.items[2].visible, false)
            t.eq(studio_files(dir), 2)
            data.vals.studio_shadow_enabled = true
            script_update(data)
            ticks(25)
            t.eq(studio.scene.items[2].visible, true)
            t.eq(studio_files(dir), 3)
            no_failures(world)
            script_unload()
        end)
    end)

    t.test("studio: background types (solid colour image, user image, unreadable image, leftovers)", function()
        scenario(function(obs, world, data, dir)
            desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio = find(world, SCENE)
            local bg_src = studio.scene.items[1].source
            local gradient_file = bg_src.settings.vals.file

            -- a solid colour is a small generated image on the same source: nothing is replaced
            data.vals.studio_bg_type = "color"
            data.vals.studio_bg_color1 = 0xFF336699
            script_update(data)
            ticks(25)
            local bg = studio.scene.items[1]
            t.eq(bg.source, bg_src, "the same background source")
            t.eq(bg.source.name, BG, "still at the bottom")
            t.eq(bg.source.id, "image_source")
            t.truthy(bg.source.settings.vals.file:match("studio%-solid%-v1%-%x+%.png$"), "solid colour image")
            t.truthy(exists(bg.source.settings.vals.file))
            t.eq(bg.info.bounds_type, obs.OBS_BOUNDS_STRETCH)
            t.eq(bg.locked, true)
            t.eq(exists(gradient_file), false, "gradient file deleted")
            t.eq(studio_files(dir), 3)
            t.eq(#studio.scene.items, 3)

            -- and back to the gradient, then a second Apply: still three items, frame on top
            data.vals.studio_bg_type = "gradient"
            script_update(data)
            ticks(25)
            press(world, "studio_apply_button")
            ticks(5)
            t.eq(#studio.scene.items, 3)
            t.eq(studio.scene.items[1].source, bg_src)
            t.eq(studio.scene.items[3].source.name, FRAME, "frame on top")

            -- a leftover copy from an older version (e.g. a renamed colour source) is removed
            local stray = world.add_source({ id = "color_source_v3", name = BG .. " 2", base_w = 1920, base_h = 1080 })
            world.add_item(studio, stray)
            data.vals.studio_padding = 7
            script_update(data)
            ticks(25)
            t.eq(#studio.scene.items, 3, "stray background removed")
            t.truthy(logs_text(world):find("removing the leftover source", 1, true))

            -- the user's image: used as it is, scaled to cover, never deleted
            local user = dir .. "/my-wallpaper.png"
            local png = require("cinezoom.assets.png")
            local f = assert(io.open(user, "wb"))
            f:write(png.encode(4, 4, string.rep("\200\100\50\255", 16)))
            f:close()
            data.vals.studio_bg_type = "image"
            data.vals.studio_bg_image = user
            script_update(data)
            ticks(25)
            bg = studio.scene.items[1]
            t.eq(bg.source.id, "image_source")
            t.eq(bg.source.settings.vals.file, user)
            t.eq(bg.info.bounds_type, obs.OBS_BOUNDS_SCALE_OUTER)
            data.vals.studio_bg_type = "gradient"
            script_update(data)
            ticks(25)
            t.eq(exists(user), true, "the user's image is never deleted")
            t.eq(studio.scene.items[1].info.bounds_type, obs.OBS_BOUNDS_STRETCH)

            -- an unreadable image falls back to the gradient with one warning
            data.vals.studio_bg_type = "image"
            data.vals.studio_bg_image = dir .. "/missing.png"
            script_update(data)
            ticks(25)
            t.truthy(studio.scene.items[1].source.settings.vals.file:match("studio%-gradient"), "gradient used")
            t.truthy(logs_text(world):find("cannot read the background image", 1, true))
            script_unload()
        end)
    end)

    t.test("studio: Remove goes back to Desktop and deletes everything it created", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local before = snapshot(w)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            local mask_file = frame.filters[1].settings.vals.image_path
            t.eq(world.scene_source, studio)

            press(world, "studio_remove_button")
            ticks(2)
            t.eq(world.scene_source, w.scene, "back on the Desktop scene")
            t.eq(find(world, SCENE), nil); t.eq(find(world, FRAME), nil)
            t.eq(find(world, BG), nil); t.eq(find(world, SHADOW), nil)
            t.truthy(studio.removed and frame.removed)
            t.eq(#studio.scene.items, 0); t.eq(#frame.scene.items, 0)
            t.eq(#frame.filters, 0, "mask filter removed")
            t.eq(studio_files(dir), 0, "images deleted")
            t.eq(exists(mask_file), false)
            t.truthy(deep_eq(snapshot(w), before), "Desktop items are as before Apply")
            t.truthy(crop_filter(w.display), "zoom is attached to the Desktop scene again")

            -- pressing Remove again is harmless, and Apply works again afterwards
            press(world, "studio_remove_button")
            press(world, "studio_apply_button")
            t.truthy(find(world, SCENE) and find(world, FRAME), "rebuilt")
            t.eq(studio_files(dir), 3)
            press(world, "studio_remove_button")
            t.eq(studio_files(dir), 0)
            script_unload()
            local leaks = world.leaks()
            t.eq(#leaks, 0, table.concat(leaks, "; "))
            for _, p in ipairs(world.private) do t.eq(p.refs, 0, p.name .. " refs") end
            no_failures(world)
        end)
    end)

    t.test("studio: Remove keeps the Studio scene when the user added items to it", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio = find(world, SCENE)
            local mine = obs.obs_scene_add(studio.scene, w.label)
            t.eq(#studio.scene.items, 4)
            press(world, "studio_remove_button")
            t.eq(studio.removed, nil, "scene kept")
            t.eq(find(world, SCENE), studio)
            t.eq(#studio.scene.items, 1)
            t.eq(studio.scene.items[1], mine)
            t.eq(find(world, FRAME), nil)
            t.eq(world.scene_source, w.scene, "current scene is Desktop, not the kept Studio scene")
            t.truthy(logs_text(world):find("items you added", 1, true) or logs_text(world):find("item(s) you added", 1, true))
            script_unload()
            local leaks = world.leaks()
            t.eq(#leaks, 0, table.concat(leaks, "; "))
            no_failures(world)
        end)
    end)

    t.test("studio: unload while applied leaves the studio, the files and no leaks (apart from the mask filter)", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            local backend = start(obs, world, data, dir, { fx_ripple_enabled = true, fx_sound_enabled = true })
            press(world, "studio_apply_button")
            ticks(2)
            world.press("cinezoom.toggle_zoom")
            ticks(120)
            backend.clicks = backend.clicks + 1
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            t.eq(#frame.scene.items, 2, "overlay present before unload")

            script_unload()
            t.eq(#frame.scene.items, 1, "no overlay left in the frame scene")
            t.eq(frame.scene.items[1].source, w.display)
            t.eq(#w.display.filters, 0, "crop filter removed")
            t.truthy(find(world, SCENE) and find(world, FRAME), "studio scenes stay")
            t.eq(#frame.filters, 1, "the mask stays with the frame scene")
            t.eq(studio_files(dir), 3, "studio images stay")
            t.eq(#list_dir(dir), 3, "effect files are gone")
            local leaks = world.leaks(ALLOW)
            t.eq(#leaks, 0, table.concat(leaks, "; "))
            for _, p in ipairs(world.private) do t.eq(p.refs, 0, p.name .. " refs") end
            no_failures(world)
        end)
    end)

    t.test("studio: a reload finds the studio again and regenerates a missing image at the same path", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            local gradient = studio.scene.items[1].source.settings.vals.file
            local fi = studio.scene.items[3]
            fi.info.pos.x = 77 -- the user moved it by hand
            script_unload()
            os.remove(gradient)
            t.eq(exists(gradient), false)

            clean_env()
            load_bundle(t.root, obs)
            require("cinezoom.effects").asset_dir = dir
            require("cinezoom.studio").asset_dir = dir
            require("cinezoom.platform").set_override(fake_backend(), "OSX")
            script_defaults(data)
            script_load(data)
            t.eq(exists(gradient), true, "regenerated at the same path")
            t.eq(studio.scene.items[1].source.settings.vals.file, gradient)
            t.eq(fi.info.pos.x, 77, "positions are not overwritten")
            script_update(data)
            ticks(5)
            t.eq(#find(world, FRAME).filters, 1)
            local props = script_properties()
            world.find_property(props, "diagnose_button").cb(props, nil)
            t.truthy(logs_text(world):find("applied: true", 1, true))
            t.truthy(crop_filter(w.display), "zoom attaches to the capture in the frame scene")
            -- OBS finishing its load repairs nothing when nothing is missing
            local function repairs()
                local _, n = logs_text(world):gsub("regenerating missing images", "")
                return n
            end
            t.eq(repairs(), 1)
            world.fire_event(obs.OBS_FRONTEND_EVENT_FINISHED_LOADING)
            t.eq(repairs(), 1)
            script_unload()
            local leaks = world.leaks(ALLOW)
            t.eq(#leaks, 0, table.concat(leaks, "; "))
        end)
    end)

    t.test("studio: a collection change takes the ripple overlay out of the frame scene", function()
        scenario(function(obs, world, data, dir)
            desktop(obs, world)
            local backend = start(obs, world, data, dir, { fx_ripple_enabled = true })
            press(world, "studio_apply_button")
            ticks(2)
            local frame = find(world, FRAME)
            backend.clicks = backend.clicks + 1
            ticks(1)
            t.eq(#frame.scene.items, 2)
            world.fire_event(obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING)
            t.eq(#frame.scene.items, 1, "overlay removed before the collection goes away")
            script_unload()
            no_failures(world)
        end)
    end)

    t.test("studio: a capture that has no size yet is laid out again when the first frame arrives", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world, false)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(5)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            t.truthy(studio and frame, "applied")
            local mask_before = frame.filters[1].settings.vals.image_path
            local props = script_properties()
            world.find_property(props, "diagnose_button").cb(props, nil)
            t.truthy(logs_text(world):find("guessed, waiting for the first frame", 1, true))
            t.eq(#w.display.filters, 0, "zoom is waiting for the size")

            w.display.base_w, w.display.base_h = 3024, 1964
            ticks(3)
            local mask_after = frame.filters[1].settings.vals.image_path
            t.truthy(mask_after ~= mask_before, "mask recomputed for the real picture")
            t.eq(exists(mask_before), false, "and the guessed one deleted")
            t.truthy(crop_filter(w.display), "zoom is ready")
            local _, _, tf = expected()
            t.near(studio.scene.items[3].info.scale.x, tf.scale, 1e-9)
            world.find_property(props, "diagnose_button").cb(props, nil)
            t.truthy(logs_text(world):find("source size used: 3024x1964 (measured)", 1, true))
            no_failures(world)
            script_unload()
        end)
    end)

    t.test("studio: Apply without a zoom source, or with a name clash, changes nothing", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir, { source = "cinezoom-none" })
            local count = #world.sources
            press(world, "studio_apply_button")
            t.eq(#world.sources, count)
            t.truthy(logs_text(world):find("select a display capture", 1, true))

            -- a source called like our scene, but not a scene
            data.vals.source = "Display"
            script_update(data)
            world.add_source({ id = "text_ft2_source_v2", name = SCENE })
            local before = snapshot(w)
            press(world, "studio_apply_button")
            t.eq(find(world, FRAME), nil, "nothing created")
            t.truthy(logs_text(world):find("already exists and is not a scene", 1, true))
            t.truthy(deep_eq(snapshot(w), before))
            t.truthy(crop_filter(w.display), "zoom still works on Desktop")
            script_unload()
        end)
    end)

    t.test("studio: Remove with no other scene to go back to changes nothing", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            w.scene.removed = true -- the user's scene is gone
            press(world, "studio_remove_button")
            t.truthy(find(world, SCENE) and find(world, FRAME), "studio kept")
            t.eq(#find(world, SCENE).scene.items, 3)
            t.eq(studio_files(dir), 3)
            t.eq(world.scene_source, find(world, SCENE))
            t.truthy(logs_text(world):find("no other scene to switch to", 1, true))
            t.truthy(crop_filter(w.display), "zoom is attached again")
            w.scene.removed = nil
            script_unload()
        end)
    end)

    t.test("studio: a background-named source of another kind stops Apply", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            world.add_source({ id = "text_ft2_source_v2", name = BG })
            press(world, "studio_apply_button")
            t.eq(find(world, SCENE), nil, "nothing created")
            t.truthy(logs_text(world):find("not a background or image source", 1, true))
            t.eq(find(world, BG).id, "text_ft2_source_v2", "the user's source is kept")
            t.truthy(crop_filter(w.display))
            script_unload()
        end)
    end)

    t.test("studio: an error in the studio never stops the zoom", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            -- the user deletes the frame item from the Studio scene by hand
            obs.obs_sceneitem_remove(studio.scene.items[3])
            data.vals.studio_padding = 3
            script_update(data)
            ticks(25)
            t.truthy(logs_text(world):find("Studio look", 1, true), "the failure is logged")
            local zf = crop_filter(w.display)
            world.press("cinezoom.toggle_zoom")
            ticks(240)
            t.near(zf.applied.cx, 1512, 2, "zoom unaffected")
            local failures = 0
            for _, l in ipairs(world.logs) do
                if l.msg:find("Tick failed", 1, true) then failures = failures + 1 end
            end
            t.eq(failures, 0, "no tick failure")
            script_unload()
            t.truthy(frame)
        end)
    end)

    t.test("studio: a colour change and a second Apply keep the capture visible in the frame", function()
        scenario(function(obs, world, data, dir)
            local w = desktop(obs, world)
            start(obs, world, data, dir)
            press(world, "studio_apply_button")
            ticks(2)
            local studio, frame = find(world, SCENE), find(world, FRAME)
            local bg = item_named(studio, BG).source
            local old_bg = bg.settings.vals.file

            data.vals.studio_bg_color1 = 0xFF0000FF
            script_update(data)
            ticks(25)
            t.truthy(bg.settings.vals.file ~= old_bg, "gradient file changed after a colour change")
            t.truthy(exists(bg.settings.vals.file), "new gradient exists")

            local cap = item_named(frame, "Display")
            local cap_info = deep_copy(cap.info)
            press(world, "studio_apply_button")
            ticks(5)
            cap = item_named(frame, "Display")
            t.truthy(cap ~= nil, "capture still in the frame scene")
            t.truthy(cap.visible ~= false, "capture visible")
            t.truthy(deep_eq(cap.info, cap_info), "capture transform unchanged by a second Apply")
            t.truthy(crop_filter(w.display), "zoom attached again")
            local fi = item_named(studio, FRAME)
            t.truthy(fi ~= nil and fi.visible ~= false, "frame item present")
            t.eq(studio.scene.items[3].source.name, FRAME, "frame on top of background and shadow")
            no_failures(world)
            script_unload()
        end)
    end)
end
