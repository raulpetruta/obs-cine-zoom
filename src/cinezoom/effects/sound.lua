-- Click sound: a small pool of private ffmpeg_sources, each attached to a free output channel so the
-- click is part of the audio mix (recording and stream). Private sources are never saved and
-- channels from 7 up are not saved either, so nothing ends up in the user's scene collection.
local obs = obslua
local log = require("cinezoom.log")
local opt = require("cinezoom.obs.opt")

local M = {}

M.VOICES = 2            -- a new click restarts the idle source, not the one still finishing
local FIRST_CHANNEL = 63
local LAST_CHANNEL = 8
local ALL_TRACKS = 0x3F

local Sound = {}
Sound.__index = Sound

---
---@return table sound controller (creates nothing until configure)
function M.new()
    return setmetatable({ voices = {}, next_voice = 1, path = nil }, Sound)
end

local function file_settings(path)
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "local_file", path)
    obs.obs_data_set_bool(s, "is_local_file", true)
    obs.obs_data_set_bool(s, "looping", false)
    obs.obs_data_set_bool(s, "restart_on_activate", false)
    obs.obs_data_set_bool(s, "close_when_inactive", false)
    obs.obs_data_set_bool(s, "clear_on_media_end", true)
    obs.obs_data_set_bool(s, "hw_decode", false)
    return s
end

-- Highest free output channel (63 down to 8)
local function free_channel()
    for ch = FIRST_CHANNEL, LAST_CHANNEL, -1 do
        local cur = obs.obs_get_output_source(ch)
        if cur == nil then
            return ch
        end
        obs.obs_source_release(cur)
    end
    return nil
end

local function apply_levels(voice, cfg)
    local v = math.max(0, math.min(100, cfg.volume)) / 100
    obs.obs_source_set_volume(voice.src, v * v)
    local mon = opt(cfg.monitor and "OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT" or "OBS_MONITORING_TYPE_NONE")
    if mon ~= nil then
        obs.obs_source_set_monitoring_type(voice.src, mon)
    end
end

local function create_voice(self, index, path, cfg)
    local s = file_settings(path)
    local src = obs.obs_source_create_private("ffmpeg_source", "OBSCineZoom click " .. index, s)
    obs.obs_data_release(s)
    if src == nil then
        return nil, "could not create the ffmpeg_source"
    end
    local voice = { src = src, ch = nil }
    self.voices[#self.voices + 1] = voice
    obs.obs_source_set_audio_mixers(src, ALL_TRACKS)
    apply_levels(voice, cfg)
    -- ffmpeg_source starts playing when it is created or activated, which would click at load:
    -- stay muted until the first real play()
    obs.obs_source_set_muted(src, true)
    local ch = free_channel()
    if ch == nil then
        return nil, "no free output channel"
    end
    obs.obs_set_output_source(ch, src)
    voice.ch = ch
    return voice
end

---
-- Create the voices on first use, then apply a changed file, volume or monitoring.
---@param cfg table {volume, monitor}
---@param path string Audio file to play
---@return boolean ok
function Sound:configure(cfg, path)
    local ok, err = pcall(function()
        if #self.voices == 0 then
            for i = 1, M.VOICES do
                local voice, why = create_voice(self, i, path, cfg)
                if voice == nil then
                    error(why, 0)
                end
            end
            self.path = path
            log.debug("Click sound ready on channels %d, %d", self.voices[1].ch, self.voices[2] and self.voices[2].ch or -1)
            return
        end
        if path ~= self.path then
            for _, voice in ipairs(self.voices) do
                local s = file_settings(path)
                obs.obs_source_update(voice.src, s)
                obs.obs_data_release(s)
            end
            self.path = path
        end
        for _, voice in ipairs(self.voices) do
            apply_levels(voice, cfg)
        end
    end)
    if not ok then
        log.warn("Click sound could not be set up: %s", tostring(err))
        self:destroy()
        return false
    end
    return true
end

---
-- Play one click (round robin over the voices)
---@return boolean played
function Sound:play()
    local voice = self.voices[self.next_voice]
    if voice == nil then
        return false
    end
    self.next_voice = self.next_voice % #self.voices + 1
    obs.obs_source_set_muted(voice.src, false)
    local restart = opt("obs_source_media_restart")
    if restart ~= nil then
        local ok, err = pcall(restart, voice.src)
        if not ok then
            log.debug("media_restart failed: %s", tostring(err))
            restart = nil
        end
    end
    if restart == nil then
        -- No restart call: updating the settings makes the source reopen the file
        local s = file_settings(self.path)
        obs.obs_source_update(voice.src, s)
        obs.obs_data_release(s)
    end
    return true
end

---
-- OBS may clear output channels when the scene collection changes: put our sources back
function Sound:reattach()
    for _, voice in ipairs(self.voices) do
        if voice.ch ~= nil then
            local ok, err = pcall(function()
                local cur = obs.obs_get_output_source(voice.ch)
                -- compare names: wrappers of the same source are not always the same object
                local ours = false
                if cur ~= nil then
                    ours = obs.obs_source_get_name(cur) == obs.obs_source_get_name(voice.src)
                    obs.obs_source_release(cur)
                end
                if not ours then
                    obs.obs_set_output_source(voice.ch, voice.src)
                    log.debug("Click sound re-attached to channel %d", voice.ch)
                end
            end)
            if not ok then
                log.debug("Click sound re-attach failed: %s", tostring(err))
            end
        end
    end
end

function Sound:destroy()
    for _, voice in ipairs(self.voices) do
        pcall(function()
            if voice.ch ~= nil then
                local cur = obs.obs_get_output_source(voice.ch)
                if cur ~= nil then
                    local ours = obs.obs_source_get_name(cur) == obs.obs_source_get_name(voice.src)
                    obs.obs_source_release(cur)
                    if ours then
                        obs.obs_set_output_source(voice.ch, nil)
                    end
                end
            end
        end)
        pcall(obs.obs_source_release, voice.src)
    end
    self.voices = {}
    self.next_voice = 1
    self.path = nil
end

---
---@return table lines for Diagnose
function Sound:describe()
    if #self.voices == 0 then
        return { "sound: off" }
    end
    local lines = { "sound: file " .. tostring(self.path) }
    for i, voice in ipairs(self.voices) do
        local ok, text = pcall(function()
            return string.format("voice %d: channel %s, media state %s, volume %.3f, muted %s, monitoring %s", i,
                tostring(voice.ch), tostring(obs.obs_source_media_get_state(voice.src)),
                obs.obs_source_get_volume(voice.src), tostring(obs.obs_source_muted(voice.src)),
                tostring(obs.obs_source_get_monitoring_type(voice.src)))
        end)
        lines[#lines + 1] = ok and text or string.format("voice %d: channel %s (state unavailable: %s)", i,
            tostring(voice.ch), tostring(text))
    end
    return lines
end

return M
