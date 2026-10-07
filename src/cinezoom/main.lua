-- OBSCineZoom entry point. install(env) defines the script_* callbacks OBS looks for.
-- All state lives in locals inside install(), so nothing else leaks into the global table.
local obs = obslua

local log = require("cinezoom.log")
local version = require("cinezoom.version")
local geometry = require("cinezoom.geometry")
local camera = require("cinezoom.camera")
local deadzone = require("cinezoom.deadzone")
local autozoom = require("cinezoom.autozoom")
local platform = require("cinezoom.platform")
local sources = require("cinezoom.obs.sources")
local sceneitem = require("cinezoom.obs.sceneitem")
local opt = require("cinezoom.obs.opt")
local fx_mod = require("cinezoom.effects")
local studio_mod = require("cinezoom.studio")
local settings_mod = require("cinezoom.settings")
local remote_mod = require("cinezoom.remote")
local diagnose = require("cinezoom.diagnose")

local M = {}

M.VERSION = "0.2.0"

local HOTKEY_KEYS = {
    zoom = "cinezoom.hotkey.zoom",
    follow = "cinezoom.hotkey.follow",
    auto = "cinezoom.hotkey.auto",
}

local HELP = [[
----------------------------------------------------
OBSCineZoom v%s
Based on obs-zoom-to-mouse by BlankSourceCode (MIT)
----------------------------------------------------
Zoom the selected display-capture source to follow the mouse.

Hotkeys (set them in OBS Settings > Hotkeys):
  OBSCineZoom: Toggle zoom to mouse / Toggle follow mouse / Toggle auto-zoom

Source: the display capture in the current scene. "Allow any zoom source" needs a manual position.
Zoom Factor: how far to zoom in.
Motion: how snappy the camera is (a critically damped spring, so no overshoot).
Follow: Auto follow starts tracking when you zoom in; the Deadzone is the area around the
  view center where the mouse can move without the view following.
Auto-zoom: zoom in on clicks, zoom out after a pause. Typing and fast mouse movement are optional.
Click effects (off by default): a click sound and a click ripple. "Test click effects" tries them.
Studio look (off until you press Apply studio look): an inset, rounded, shadowed picture on a background,
  in its own scenes. Your own scene is not changed; Remove studio look deletes them again.
Manual source position: override the display position/size (mouse units) when it cannot be found.
Diagnose: log everything needed for a bug report, then probe the mouse for 5 seconds.
]]

---
-- Install the script_* callbacks into env (the script's global table)
---@param env table
function M.install(env)
    -- Looked up when used so tests can pretend to be on another platform
    local function OS() return platform.os_name() end
    local obs_version = obs.obs_get_version_string()

    local cfg = nil              -- settings table (see settings.lua)
    local backend = nil          -- mouse backend
    local si = sceneitem.new()
    local cam = camera.new(1920, 1080)
    local az = autozoom.new()
    local remote = remote_mod.new()
    remote.running = false
    local fx = fx_mod.new()      -- click effects (nothing is created until one is switched on)
    local fx_proj = nil          -- {mx, my, inside} of the current tick, nil if there was no projection
    local fx_errors = 0          -- consecutive fx_tick failures
    local studio = studio_mod.new() -- the studio scenes (nothing is created until "Apply studio look")

    local display, display_note = nil, "not resolved yet"
    local clock = 0
    local zoomed = false         -- the camera is zooming/zoomed in
    local following = false
    local target = { x = 960, y = 540 } -- camera center target (camera space)
    local last_input = nil       -- latest raw input sample
    local prev_counts = { clicks = nil, keys = nil }
    local remote_clock = 0
    local input_error_logged = false

    local hotkeys = { zoom = nil, follow = nil, auto = nil }
    local obs_loaded = false
    local script_loaded = false

    ----------------------------------------------------------------------
    -- helpers
    ----------------------------------------------------------------------
    local function stiffness_changed()
        camera.set_stiffness(cam, settings_mod.stiffness(cfg))
    end

    -- Forget any zoom: used when the source, scene or size changes
    local function reset_zoom()
        zoomed, following = false, false
        autozoom.reset(az)
        camera.set_bounds(cam, math.max(si.cam_w, 1), math.max(si.cam_h, 1))
        target.x, target.y = cam.w / 2, cam.h / 2
    end

    local function resolve_display()
        if si.source == nil and not (cfg.override.enabled and cfg.override.w > 0) then
            display, display_note = nil, "no zoom source"
            return
        end
        display, display_note = sources.resolve_display(si.source, {
            os = OS(), backend = backend, override = cfg.override,
        })
        if display then
            log.debug("Display resolved via %s: %sx%s @ %s,%s", tostring(display.method),
                display.w, display.h, display.x, display.y)
        end
    end

    -- Find the scene item for the selected source and prepare it
    local function attach()
        fx:detach_host() -- the overlay item must not outlive the scene item it sits above
        local name = cfg.source
        if name == "" or name == sources.NONE then
            -- No zoom source: restore everything so users can edit crops, then re-select
            si:release()
            display, display_note = nil, "no zoom source"
            reset_zoom()
            return
        end

        local ok = si:attach(name, function(src)
            return sources.is_capture(obs.obs_source_get_id(src), OS())
        end)
        if ok and not si.is_capture and not cfg.override.enabled then
            log.error("Selected Zoom Source is not a display capture source. " ..
                "You MUST enable 'Set manual source position' and set the correct size and position.")
        end
        resolve_display()
        reset_zoom()
    end

    -- Camera-space position of a global mouse position (nil if there is no display yet)
    local function project(gx, gy)
        if gx == nil or display == nil or not si.ready then
            return nil
        end
        local lx, ly = geometry.to_display_local(gx, gy, display)
        local px, py = geometry.to_source_px(lx, ly, display, si.base_w, si.base_h)
        local cx, cy = geometry.to_camera_space(px, py, si.user_crop)
        return px, py, cx, cy
    end

    local function read_input()
        local gx, gy
        if remote.mouse then
            gx, gy = remote.mouse.x, remote.mouse.y
        else
            gx, gy = backend.mouse()
        end
        local left, clicks = backend.buttons()
        local keys = backend.key_activity()
        return gx, gy, left, clicks, keys
    end

    local function sample()
        local s = last_input
        if not s then
            local ok, gx, gy, left, clicks, keys = pcall(read_input)
            s = ok and { gx = gx, gy = gy, left = left, clicks = clicks, keys = keys } or {}
        end
        local sx, sy, cx, cy = project(s.gx, s.gy)
        return { gx = s.gx, gy = s.gy, sx = sx, sy = sy, cx = cx, cy = cy,
            left = s.left, clicks = s.clicks, keys = s.keys }
    end

    local function diagnose_context()
        return {
            version = M.VERSION, obs_version = obs_version, backend = backend, si = si,
            display = display, display_note = display_note, sample = sample, fx = fx, studio = studio,
            state = { zoomed = zoomed, following = following, auto = az.enabled },
        }
    end

    -- Difference of a monotonically increasing counter between ticks
    local function delta(name, value)
        local d = 0
        if value ~= nil and prev_counts[name] ~= nil and value > prev_counts[name] then
            d = value - prev_counts[name]
        end
        prev_counts[name] = value
        return d
    end

    ----------------------------------------------------------------------
    -- hotkeys
    ----------------------------------------------------------------------
    local function on_toggle_zoom(pressed)
        if not pressed then return end
        if not si.ready then
            log.warn("Cannot zoom yet: no zoom source is ready. Select a Zoom Source and run Diagnose if this persists.")
            return
        end
        if zoomed then
            log.debug("Zooming out")
            autozoom.set_manual(az, clock, false)
        else
            log.debug("Zooming in")
            local focus = nil
            if last_input then
                local _, _, cx, cy = project(last_input.gx, last_input.gy)
                if cx then focus = { x = cx, y = cy } end
            end
            autozoom.set_manual(az, clock, true, focus)
        end
    end

    local function on_toggle_follow(pressed)
        if pressed then
            following = not following
            log.debug("Tracking mouse is %s", following and "on" or "off")
        end
    end

    local function on_toggle_auto(pressed)
        if pressed then
            autozoom.set_enabled(az, not az.enabled)
            log.info("Auto-zoom is %s", az.enabled and "on" or "off")
        end
    end

    ----------------------------------------------------------------------
    -- the tick loop
    ----------------------------------------------------------------------
    local function zoom_tick(seconds)
        fx_proj = nil
        if not script_loaded or backend == nil then
            return
        end
        clock = clock + seconds
        diagnose.tick(seconds)

        if remote.server and clock - remote_clock >= (cfg.socket.poll / 1000) then
            remote_clock = clock
            remote_mod.poll(remote)
        end

        local ok, gx, gy, left, clicks, keys = pcall(read_input)
        if not ok then
            if not input_error_logged then
                input_error_logged = true
                log.error("Mouse backend failed (%s). Mouse following is disabled.", tostring(gx))
            end
            backend = require("cinezoom.platform.null").new(tostring(gx))
            return
        end
        last_input = { gx = gx, gy = gy, left = left, clicks = clicks, keys = keys }

        if si.item == nil then
            return
        end

        -- A source can report size 0 until its first frame, and the size can change later
        if si:poll_size() then
            resolve_display()
            reset_zoom()
            pcall(studio.on_source_resized, studio, si)
        end
        if not si.ready then
            return
        end

        local _, _, mx, my = project(gx, gy)
        local inside = mx ~= nil and mx >= 0 and my >= 0 and mx < si.cam_w and my < si.cam_h
        fx_proj = { mx = mx, my = my, inside = inside }

        local res = autozoom.update(az, clock, {
            x = mx, y = my, inside = inside,
            clicks = delta("clicks", clicks), left_down = left, keys = delta("keys", keys),
            cam_w = si.cam_w,
        })
        if res.zoom ~= zoomed then
            zoomed = res.zoom
            following = zoomed and cfg.follow
            log.debug("Zoom %s", zoomed and "in" or "out")
        end
        if res.focus then
            target.x, target.y = res.focus.x, res.focus.y
        end

        if zoomed then
            local vw, vh = si.cam_w / cfg.zoom, si.cam_h / cfg.zoom
            if following and mx ~= nil and (inside or cfg.follow_outside) then
                target.x, target.y = deadzone.apply(target.x, target.y, mx, my, vw, vh, cfg.deadzone)
            end
            target.x = geometry.clamp(target.x, vw / 2, si.cam_w - vw / 2)
            target.y = geometry.clamp(target.y, vh / 2, si.cam_h - vh / 2)
        end

        camera.set_target(cam, target.x, target.y, zoomed and cfg.zoom or 1)
        camera.step(cam, seconds)
        si:set_crop(camera.rect(cam))
    end

    -- Click effects. Runs after the zoom tick, so "zoomed" already includes an auto zoom-in
    -- caused by this very click. The click count has its own counter key: autozoom's is untouched.
    local function fx_tick(seconds)
        if not fx:active() then
            prev_counts.fx_clicks = nil -- do not replay clicks made while the effects were off
            return
        end
        if last_input == nil then
            return
        end
        local n = delta("fx_clicks", last_input.clicks)
        local proj = fx_proj
        local inside = proj ~= nil and proj.inside
        if n > 0 and cfg.fx.only_inside and not inside then
            n = 0
        end
        if n > 0 and cfg.fx.only_zoomed and not zoomed then
            n = 0
        end
        local cam_pt = proj ~= nil and proj.mx ~= nil and { x = proj.mx, y = proj.my } or nil
        fx:on_click(n, inside, cam_pt, si, clock)
        fx:tick(si, clock)
    end

    -- An error in the effects must never stop the zoom: three in a row turn them off
    local function run_fx(seconds)
        local ok, err = pcall(fx_tick, seconds)
        if ok then
            fx_errors = 0
            return
        end
        fx_errors = fx_errors + 1
        if fx_errors >= 3 then
            fx_errors = 0
            log.error("Click effects failed three times in a row (%s). They are turned off until you change a setting.",
                tostring(err))
            pcall(fx.disable, fx)
        else
            log.warn("Click effects error: %s", tostring(err))
        end
    end

    -- Studio look changes and layout fixes. An error here never reaches the zoom: sync_safe logs it.
    local function studio_tick()
        local ok, err = pcall(studio.tick, studio, clock, si)
        if not ok then
            log.warn("Studio look error: %s", tostring(err))
        end
    end

    local function tick(seconds)
        zoom_tick(seconds)
        if script_loaded and backend ~= nil then
            run_fx(seconds)
            studio_tick()
        end
    end

    -- What the studio needs from the zoom side
    local function studio_context()
        return {
            si = si, fx = fx, attach = attach,
            is_capture = function(src) return sources.is_capture(obs.obs_source_get_id(src), OS()) end,
        }
    end

    ----------------------------------------------------------------------
    -- OBS events
    ----------------------------------------------------------------------
    local function on_transition_start()
        log.debug("Transition started")
        fx:detach_host()
        -- Remove the crop as the transition starts to avoid showing the old crop for a moment
        si:release()
        reset_zoom()
    end

    -- These constants are missing in some OBS versions
    local EVENT_COLLECTION_CHANGING = opt("OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING")
    local EVENT_COLLECTION_CHANGED = opt("OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED")
    local EVENT_EXIT = opt("OBS_FRONTEND_EVENT_EXIT")

    local function on_frontend_event(event)
        if EVENT_COLLECTION_CHANGING ~= nil and event == EVENT_COLLECTION_CHANGING
            or EVENT_EXIT ~= nil and event == EVENT_EXIT then
            -- Nothing of ours may be left in scenes that are about to go away
            fx:on_collection_changing()
            pcall(studio.on_collection_changing, studio)
        elseif EVENT_COLLECTION_CHANGED ~= nil and event == EVENT_COLLECTION_CHANGED then
            pcall(fx.on_collection_changed, fx)
            pcall(studio.repair, studio, cfg, si)
        elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
            log.debug("OBS Scene changed")
            -- Scene change can happen before OBS has completely loaded
            if obs_loaded then
                attach()
            end
        elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
            log.debug("OBS Loaded")
            obs_loaded = true
            attach()
            pcall(studio.repair, studio, cfg, si)
        elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
            log.debug("OBS Shutting down")
            -- Fail-safe for unloading the script during shutdown
            if script_loaded then
                env.script_unload()
            end
        end
    end

    ----------------------------------------------------------------------
    -- script_* callbacks
    ----------------------------------------------------------------------
    function env.script_description()
        return "Zoom the selected display-capture source to follow the mouse (OBSCineZoom " .. M.VERSION .. ")"
    end

    function env.script_defaults(settings)
        settings_mod.defaults(settings)
    end

    function env.script_properties()
        return settings_mod.properties({
            os = OS(),
            cfg = function() return cfg end,
            on_refresh = function()
                resolve_display()
            end,
            on_diagnose = function()
                diagnose.run(diagnose_context())
            end,
            on_help = function()
                log.info(string.format(HELP, M.VERSION))
            end,
            on_studio_apply = function()
                local ok, res = pcall(studio.apply, studio, cfg, studio_context())
                if not ok then
                    log.error("Studio look failed: %s", tostring(res))
                end
            end,
            on_studio_remove = function()
                local ok, res = pcall(studio.remove, studio, studio_context())
                if not ok then
                    log.error("Studio look could not be removed: %s", tostring(res))
                end
            end,
            on_fx_test = function()
                local s = sample()
                local ok, msg = pcall(fx.test_click, fx, s.cx ~= nil and { x = s.cx, y = s.cy } or nil, si, clock)
                log.info("%s", ok and msg or ("Click effects test failed: " .. tostring(msg)))
            end,
        })
    end

    function env.script_load(settings)
        cfg = settings_mod.read(settings)
        log.debug_enabled = cfg.debug
        backend = platform.get()
        az = autozoom.new(cfg.auto)
        stiffness_changed()

        -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
        local current_scene = obs.obs_frontend_get_current_scene()
        obs_loaded = current_scene ~= nil -- Current scene is nil on first OBS load
        if current_scene ~= nil then
            obs.obs_source_release(current_scene)
        end

        -- Register hotkeys and restore their bindings
        hotkeys.zoom = obs.obs_hotkey_register_frontend("cinezoom.toggle_zoom", "OBSCineZoom: Toggle zoom to mouse", on_toggle_zoom)
        hotkeys.follow = obs.obs_hotkey_register_frontend("cinezoom.toggle_follow", "OBSCineZoom: Toggle follow mouse during zoom", on_toggle_follow)
        hotkeys.auto = obs.obs_hotkey_register_frontend("cinezoom.toggle_auto", "OBSCineZoom: Toggle auto-zoom", on_toggle_auto)
        for name, id in pairs(hotkeys) do
            local array = obs.obs_data_get_array(settings, HOTKEY_KEYS[name])
            obs.obs_hotkey_load(id, array)
            obs.obs_data_array_release(array)
        end

        obs.obs_frontend_add_event_callback(on_frontend_event)

        -- Add the transition_start handler to each transition (the global source_transition_start event never fires)
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for _, s in pairs(transitions) do
                log.debug("Adding transition_start listener to %s", obs.obs_source_get_name(s))
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_connect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        if not backend.ok then
            log.warn("Mouse backend '%s' is not working: %s. Mouse following will not work. Run Diagnose for details.",
                backend.name, tostring(backend.reason))
        elseif backend.reason then
            log.warn("%s", backend.reason)
        end
        if cfg.debug then
            log.debug("Settings: %s", log.dump(cfg))
        end

        cfg.source = "" -- script_update sets it, which triggers the first attach
        script_loaded = true
        if obs_loaded then
            pcall(studio.repair, studio, cfg, si) -- images that went missing while the script was off
        end
    end

    function env.script_update(settings)
        local old = cfg
        cfg = settings_mod.read(settings)
        log.debug_enabled = cfg.debug
        stiffness_changed()
        autozoom.configure(az, cfg.auto)

        if cfg.source ~= old.source and obs_loaded then
            attach()
        elseif settings_mod.override_changed(old.override, cfg.override) and obs_loaded then
            resolve_display()
        end

        pcall(studio.on_settings, studio, cfg.studio, clock)

        local okfx, errfx = pcall(fx.configure, fx, cfg.fx)
        if not okfx then
            log.error("Click effects could not be set up: %s", tostring(errfx))
            pcall(fx.destroy, fx)
        end

        local sock, osock = cfg.socket, old.socket
        if sock.enabled ~= remote.running then
            if sock.enabled then
                remote.running = remote_mod.start(remote, sock.port)
            else
                remote_mod.stop(remote)
                remote.running = false
            end
        elseif sock.enabled and (sock.port ~= osock.port or sock.poll ~= osock.poll) then
            remote_mod.stop(remote)
            remote.running = remote_mod.start(remote, sock.port)
        end
    end

    function env.script_tick(seconds)
        local ok, err = pcall(tick, seconds)
        if not ok then
            log.error("Tick failed: %s", tostring(err))
        end
    end

    function env.script_save(settings)
        for name, id in pairs(hotkeys) do
            if id ~= nil then
                local array = obs.obs_hotkey_save(id)
                obs.obs_data_set_array(settings, HOTKEY_KEYS[name], array)
                obs.obs_data_array_release(array)
            end
        end
    end

    function env.script_unload()
        script_loaded = false
        diagnose.cancel()

        -- 29.1.2 and below seems to crash if you do this, so we skip it as the script is closing anyway
        if version.at_least(obs_version, 29, 1, 3) then
            local function step(what, fn)
                local ok, err = pcall(fn)
                if not ok then
                    log.warn("Unload step '%s' failed: %s", what, tostring(err))
                end
            end

            step("transitions", function()
                local transitions = obs.obs_frontend_get_transitions()
                if transitions ~= nil then
                    for _, s in pairs(transitions) do
                        local handler = obs.obs_source_get_signal_handler(s)
                        obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
                    end
                    obs.source_list_release(transitions)
                end
            end)
            step("hotkeys", function()
                for name, id in pairs(hotkeys) do
                    if id ~= nil then
                        obs.obs_hotkey_unregister(id) -- takes the hotkey id, not the callback
                        hotkeys[name] = nil
                    end
                end
            end)
            step("frontend callback", function() obs.obs_frontend_remove_event_callback(on_frontend_event) end)
            step("click effects", function() fx:destroy() end)
            step("scene item", function() si:release() end)
        end

        if backend ~= nil then
            pcall(backend.close)
            backend = nil
        end
        if remote.server ~= nil then
            remote_mod.stop(remote)
            remote.running = false
        end
    end
end

return M
