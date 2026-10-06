-- Settings: defaults, reading them into a plain table, and the properties (UI) panel.
local obs = obslua
local camera = require("cinezoom.camera")
local sources = require("cinezoom.obs.sources")
local remote = require("cinezoom.remote")

local M = {}

---
-- Defaults for a fresh script
function M.defaults(s)
    obs.obs_data_set_default_double(s, "zoom_value", 2)
    obs.obs_data_set_default_string(s, "motion_preset", "mellow")
    obs.obs_data_set_default_double(s, "motion_stiffness", 120)
    obs.obs_data_set_default_bool(s, "follow", true)
    obs.obs_data_set_default_bool(s, "follow_outside_bounds", false)
    obs.obs_data_set_default_int(s, "follow_deadzone", 40)
    obs.obs_data_set_default_bool(s, "allow_all_sources", false)

    obs.obs_data_set_default_bool(s, "auto_enabled", false)
    obs.obs_data_set_default_double(s, "auto_idle", 2.5)
    obs.obs_data_set_default_double(s, "auto_min_hold", 0.8)
    obs.obs_data_set_default_bool(s, "auto_typing", false)
    obs.obs_data_set_default_bool(s, "auto_fast_out", false)

    obs.obs_data_set_default_bool(s, "use_override", false)
    obs.obs_data_set_default_int(s, "override_x", 0)
    obs.obs_data_set_default_int(s, "override_y", 0)
    obs.obs_data_set_default_int(s, "override_w", 1920)
    obs.obs_data_set_default_int(s, "override_h", 1080)
    obs.obs_data_set_default_double(s, "override_sx", 0)
    obs.obs_data_set_default_double(s, "override_sy", 0)

    obs.obs_data_set_default_bool(s, "use_socket", false)
    obs.obs_data_set_default_int(s, "socket_port", 12345)
    obs.obs_data_set_default_int(s, "socket_poll", 10)

    -- Click effects: everything is off until switched on
    obs.obs_data_set_default_bool(s, "fx_sound_enabled", false)
    obs.obs_data_set_default_int(s, "fx_sound_volume", 50)
    obs.obs_data_set_default_bool(s, "fx_sound_monitor", false)
    obs.obs_data_set_default_string(s, "fx_sound_file", "")
    obs.obs_data_set_default_bool(s, "fx_ripple_enabled", false)
    obs.obs_data_set_default_int(s, "fx_ripple_color", 0xFFFF8D4C) -- #4C8DFF, stored as 0xAABBGGRR
    obs.obs_data_set_default_int(s, "fx_ripple_size", 72)
    obs.obs_data_set_default_double(s, "fx_ripple_duration", 0.5)
    obs.obs_data_set_default_int(s, "fx_ripple_thickness", 5)
    obs.obs_data_set_default_int(s, "fx_ripple_opacity", 85)
    obs.obs_data_set_default_bool(s, "fx_ripple_zoom_scale", true)
    obs.obs_data_set_default_string(s, "fx_ripple_file", "")
    obs.obs_data_set_default_bool(s, "fx_only_inside", true)
    obs.obs_data_set_default_bool(s, "fx_only_zoomed", false)

    obs.obs_data_set_default_bool(s, "debug_logs", false)
end

---
-- Read the settings into a plain table
---@return table cfg
function M.read(s)
    return {
        source = obs.obs_data_get_string(s, "source"),
        zoom = obs.obs_data_get_double(s, "zoom_value"),
        preset = obs.obs_data_get_string(s, "motion_preset"),
        custom_k = obs.obs_data_get_double(s, "motion_stiffness"),
        follow = obs.obs_data_get_bool(s, "follow"),
        follow_outside = obs.obs_data_get_bool(s, "follow_outside_bounds"),
        deadzone = obs.obs_data_get_int(s, "follow_deadzone") / 100,
        allow_all = obs.obs_data_get_bool(s, "allow_all_sources"),
        auto = {
            enabled = obs.obs_data_get_bool(s, "auto_enabled"),
            idle_timeout = obs.obs_data_get_double(s, "auto_idle"),
            min_hold = obs.obs_data_get_double(s, "auto_min_hold"),
            zoom_on_typing = obs.obs_data_get_bool(s, "auto_typing"),
            zoom_out_on_fast = obs.obs_data_get_bool(s, "auto_fast_out"),
        },
        override = {
            enabled = obs.obs_data_get_bool(s, "use_override"),
            x = obs.obs_data_get_int(s, "override_x"),
            y = obs.obs_data_get_int(s, "override_y"),
            w = obs.obs_data_get_int(s, "override_w"),
            h = obs.obs_data_get_int(s, "override_h"),
            sx = obs.obs_data_get_double(s, "override_sx"),
            sy = obs.obs_data_get_double(s, "override_sy"),
        },
        socket = {
            enabled = obs.obs_data_get_bool(s, "use_socket"),
            port = obs.obs_data_get_int(s, "socket_port"),
            poll = obs.obs_data_get_int(s, "socket_poll"),
        },
        fx = {
            sound = {
                enabled = obs.obs_data_get_bool(s, "fx_sound_enabled"),
                volume = obs.obs_data_get_int(s, "fx_sound_volume"),
                monitor = obs.obs_data_get_bool(s, "fx_sound_monitor"),
                file = obs.obs_data_get_string(s, "fx_sound_file"),
            },
            ripple = {
                enabled = obs.obs_data_get_bool(s, "fx_ripple_enabled"),
                color = obs.obs_data_get_int(s, "fx_ripple_color"),
                size = math.max(1, obs.obs_data_get_int(s, "fx_ripple_size")),
                duration = obs.obs_data_get_double(s, "fx_ripple_duration"),
                thickness = obs.obs_data_get_int(s, "fx_ripple_thickness"),
                opacity = obs.obs_data_get_int(s, "fx_ripple_opacity") / 100,
                zoom_scale = obs.obs_data_get_bool(s, "fx_ripple_zoom_scale"),
                file = obs.obs_data_get_string(s, "fx_ripple_file"),
            },
            only_inside = obs.obs_data_get_bool(s, "fx_only_inside"),
            only_zoomed = obs.obs_data_get_bool(s, "fx_only_zoomed"),
        },
        debug = obs.obs_data_get_bool(s, "debug_logs"),
    }
end

---
-- Spring stiffness for the chosen motion preset
---@return number
function M.stiffness(cfg)
    if cfg.preset == "custom" then
        return math.max(1, cfg.custom_k)
    end
    return camera.PRESETS[cfg.preset] or camera.PRESETS.mellow
end

---
-- True if the two override tables differ
function M.override_changed(a, b)
    for _, k in ipairs({ "enabled", "x", "y", "w", "h", "sx", "sy" }) do
        if a[k] ~= b[k] then
            return true
        end
    end
    return false
end

---
-- Build the properties panel
---@param ctx table {os, on_refresh, on_diagnose, on_help, on_fx_test}
---@return any props
function M.properties(ctx)
    local props = obs.obs_properties_create()

    -- Source
    local src = obs.obs_properties_create()
    local source_list = obs.obs_properties_add_list(src, "source", "Zoom Source",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    local allow_all = obs.obs_properties_add_bool(src, "allow_all_sources", "Allow any zoom source ")
    obs.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")
    local cfg_now = ctx.cfg and ctx.cfg() or {}
    sources.populate(source_list, ctx.os, cfg_now.allow_all or false)
    local refresh = obs.obs_properties_add_button(src, "refresh", "Refresh zoom sources", function()
        sources.populate(source_list, ctx.os, ctx.cfg and ctx.cfg().allow_all or false)
        ctx.on_refresh()
        return true
    end)
    obs.obs_property_set_long_description(refresh,
        "Re-populate the Zoom Sources dropdown and look up the display again")
    obs.obs_property_set_modified_callback(allow_all, function(_, _, settings)
        sources.populate(source_list, ctx.os, obs.obs_data_get_bool(settings, "allow_all_sources"))
        return true
    end)
    obs.obs_properties_add_group(props, "grp_source", "Source", obs.OBS_GROUP_NORMAL, src)

    -- Zoom
    local zoom = obs.obs_properties_create()
    obs.obs_properties_add_float(zoom, "zoom_value", "Zoom Factor", 1, 5, 0.1)
    obs.obs_properties_add_group(props, "grp_zoom", "Zoom", obs.OBS_GROUP_NORMAL, zoom)

    -- Motion
    local motion = obs.obs_properties_create()
    local preset = obs.obs_properties_add_list(motion, "motion_preset", "Motion",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(preset, "Slow", "slow")
    obs.obs_property_list_add_string(preset, "Mellow", "mellow")
    obs.obs_property_list_add_string(preset, "Quick", "quick")
    obs.obs_property_list_add_string(preset, "Rapid", "rapid")
    obs.obs_property_list_add_string(preset, "Custom", "custom")
    local stiffness = obs.obs_properties_add_float(motion, "motion_stiffness", "Custom stiffness", 10, 1000, 10)
    obs.obs_property_set_long_description(stiffness, "Spring stiffness for the Custom motion (higher is snappier)")
    obs.obs_property_set_visible(stiffness, (cfg_now.preset or "mellow") == "custom")
    obs.obs_property_set_modified_callback(preset, function(_, _, settings)
        local custom = obs.obs_data_get_string(settings, "motion_preset") == "custom"
        obs.obs_property_set_visible(stiffness, custom)
        return true
    end)
    obs.obs_properties_add_group(props, "grp_motion", "Motion", obs.OBS_GROUP_NORMAL, motion)

    -- Follow
    local follow = obs.obs_properties_create()
    local f1 = obs.obs_properties_add_bool(follow, "follow", "Auto follow mouse ")
    obs.obs_property_set_long_description(f1,
        "When enabled mouse tracking starts as soon as you zoom in, without the follow hotkey")
    local f2 = obs.obs_properties_add_bool(follow, "follow_outside_bounds", "Follow outside bounds ")
    obs.obs_property_set_long_description(f2,
        "Track the mouse even when the cursor is outside the zoom source")
    local f3 = obs.obs_properties_add_int_slider(follow, "follow_deadzone", "Deadzone (%)", 0, 90, 1)
    obs.obs_property_set_long_description(f3,
        "The view only moves when the mouse leaves this area around the view center. 0 follows every movement.")
    obs.obs_properties_add_group(props, "grp_follow", "Follow", obs.OBS_GROUP_NORMAL, follow)

    -- Auto-zoom
    local auto = obs.obs_properties_create()
    local a1 = obs.obs_properties_add_bool(auto, "auto_enabled", "Zoom automatically on click ")
    obs.obs_property_set_long_description(a1, "Zoom in on clicks and zoom out when you stop interacting")
    obs.obs_properties_add_float(auto, "auto_idle", "Zoom out after (s)", 0.5, 20, 0.1)
    obs.obs_properties_add_float(auto, "auto_min_hold", "Minimum hold (s)", 0, 10, 0.1)
    obs.obs_properties_add_bool(auto, "auto_typing", "Zoom in when typing ")
    obs.obs_properties_add_bool(auto, "auto_fast_out", "Zoom out on fast mouse movement ")
    obs.obs_properties_add_group(props, "grp_auto", "Auto-zoom", obs.OBS_GROUP_NORMAL, auto)

    -- Click sound
    local snd = obs.obs_properties_create()
    obs.obs_properties_add_int_slider(snd, "fx_sound_volume", "Volume (%)", 0, 100, 1)
    local s2 = obs.obs_properties_add_bool(snd, "fx_sound_monitor", "Also play locally (monitor) ")
    obs.obs_property_set_long_description(s2, "Also play the click through your monitoring device " ..
        "(OBS Settings > Audio > Advanced). The click always goes into the recording and stream.")
    local s3 = obs.obs_properties_add_path(snd, "fx_sound_file", "Custom sound file ", obs.OBS_PATH_FILE,
        "Audio (*.wav *.mp3 *.ogg *.flac)", nil)
    obs.obs_property_set_long_description(s3, "Leave empty for the built-in click")
    obs.obs_properties_add_group(props, "fx_sound_enabled", "Click sound ", obs.OBS_GROUP_CHECKABLE, snd)

    -- Click ripple
    local rip = obs.obs_properties_create()
    obs.obs_properties_add_color(rip, "fx_ripple_color", "Color ")
    obs.obs_properties_add_int(rip, "fx_ripple_size", "Size (px)", 20, 400, 1)
    obs.obs_properties_add_float(rip, "fx_ripple_duration", "Duration (s)", 0.1, 2.0, 0.05)
    obs.obs_properties_add_int(rip, "fx_ripple_thickness", "Ring thickness (px)", 1, 40, 1)
    obs.obs_properties_add_int_slider(rip, "fx_ripple_opacity", "Opacity (%)", 10, 100, 1)
    local r1 = obs.obs_properties_add_bool(rip, "fx_ripple_zoom_scale", "Scale with zoom ")
    obs.obs_property_set_long_description(r1, "Make the ripple larger when the view is zoomed in")
    local r2 = obs.obs_properties_add_path(rip, "fx_ripple_file", "Custom image ", obs.OBS_PATH_FILE,
        "Images (*.png *.webp *.gif *.jpg)", nil)
    obs.obs_property_set_long_description(r2, "Leave empty for the built-in ring. The color is ignored for a custom image")
    obs.obs_properties_add_group(props, "fx_ripple_enabled", "Click ripple ", obs.OBS_GROUP_CHECKABLE, rip)

    -- Click effects (shared)
    local fx = obs.obs_properties_create()
    obs.obs_properties_add_bool(fx, "fx_only_inside", "Only clicks on the captured display ")
    obs.obs_properties_add_bool(fx, "fx_only_zoomed", "Only while zoomed in ")
    local test = obs.obs_properties_add_button(fx, "fx_test_button", "Test click effects", function()
        ctx.on_fx_test()
        return false
    end)
    obs.obs_property_set_long_description(test, "Play the sound and show a ripple at the current mouse position")
    obs.obs_properties_add_group(props, "grp_fx", "Click effects", obs.OBS_GROUP_NORMAL, fx)

    -- Display override
    local override = obs.obs_properties_create()
    local o1 = obs.obs_properties_add_int(override, "override_x", "X", -20000, 20000, 1)
    obs.obs_properties_add_int(override, "override_y", "Y", -20000, 20000, 1)
    obs.obs_properties_add_int(override, "override_w", "Width", 0, 20000, 1)
    obs.obs_properties_add_int(override, "override_h", "Height", 0, 20000, 1)
    local o5 = obs.obs_properties_add_float(override, "override_sx", "Scale X ", 0, 100, 0.01)
    local o6 = obs.obs_properties_add_float(override, "override_sy", "Scale Y ", 0, 100, 0.01)
    obs.obs_property_set_long_description(o1,
        "Position and size of the display in MOUSE units (points on macOS, pixels on Windows/Linux)")
    obs.obs_property_set_long_description(o5, "0 = automatic (source size / Width). Set it for cloned or scaled sources")
    obs.obs_property_set_long_description(o6, "0 = automatic (source size / Height). Set it for cloned or scaled sources")
    obs.obs_properties_add_group(props, "use_override", "Set manual source position ",
        obs.OBS_GROUP_CHECKABLE, override)

    -- Remote mouse (only when ljsocket is installed)
    if remote.available then
        local sock = obs.obs_properties_create()
        local r1 = obs.obs_properties_add_int(sock, "socket_port", "Port ", 1024, 65535, 1)
        local r2 = obs.obs_properties_add_int(sock, "socket_poll", "Poll Delay (ms) ", 0, 1000, 1)
        obs.obs_property_set_long_description(r1, "Uncheck and re-check the listener to apply a new port")
        obs.obs_property_set_long_description(r2, "Uncheck and re-check the listener to apply a new poll delay")
        obs.obs_properties_add_group(props, "use_socket", "Enable remote mouse listener ",
            obs.OBS_GROUP_CHECKABLE, sock)
    end

    obs.obs_properties_add_button(props, "diagnose_button", "Diagnose", function()
        ctx.on_diagnose()
        return false
    end)
    obs.obs_properties_add_button(props, "help_button", "Help", function()
        ctx.on_help()
        return false
    end)
    local debug = obs.obs_properties_add_bool(props, "debug_logs", "Enable debug logging ")
    obs.obs_property_set_long_description(debug,
        "Print extra diagnostics to the script log (warnings and errors are always shown)")

    return props
end

return M
