-- Click effects controller: owns the generated asset files, the sound and the ripple.
-- Both effects are off by default, and nothing is created until one is switched on.
local log = require("cinezoom.log")
local png = require("cinezoom.assets.png")
local wav = require("cinezoom.assets.wav")
local sound_mod = require("cinezoom.effects.sound")
local ripple_mod = require("cinezoom.effects.ripple")

local M = {}

-- Test hook: when set, assets are written to this directory only
M.asset_dir = nil

local RING_TEX = 256 -- pixels of the generated ring image

local Fx = {}
Fx.__index = Fx

---
---@return table controller
function M.new()
    return setmetatable({ cfg = nil, sound = nil, ripple = nil, assets = {}, warned = {}, off = false }, Fx)
end

-- Directories to try for the generated files, best first. Temp comes before the script folder:
-- the files are disposable, and that folder may be read-only, synced or a git checkout.
local function candidate_dirs()
    if M.asset_dir ~= nil then
        return { M.asset_dir }
    end
    local dirs = {}
    for _, var in ipairs({ "TMPDIR", "TEMP", "TMP" }) do
        local v = os.getenv(var)
        if v ~= nil and v ~= "" then
            dirs[#dirs + 1] = v
        end
    end
    dirs[#dirs + 1] = "/tmp"
    local sp = rawget(_G, "script_path")
    if type(sp) == "function" then
        local ok, dir = pcall(sp)
        if ok and type(dir) == "string" and dir ~= "" then
            dirs[#dirs + 1] = dir
        end
    end
    return dirs
end

local function join(dir, name)
    if dir:match("[/\\]$") then
        return dir .. name
    end
    return dir .. "/" .. name
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

-- Path of a generated file, (re)written when it is missing or has the wrong size
function Fx:asset(name, make)
    local known = self.assets[name]
    if known ~= nil and file_size(known.path) == known.size then
        return known.path
    end
    local bytes = make()
    for _, dir in ipairs(candidate_dirs()) do
        local path = join(dir, name)
        local f = io.open(path, "wb")
        if f ~= nil then
            local okw = f:write(bytes)
            f:close()
            if okw then
                self.assets[name] = { path = path, size = #bytes }
                return path
            end
        end
    end
    return nil
end

-- A user-chosen file wins when it is readable, otherwise warn once and use the generated one
function Fx:custom(path)
    if path == nil or path == "" then
        return nil
    end
    if file_size(path) ~= nil then
        return path
    end
    if not self.warned[path] then
        self.warned[path] = true
        log.warn("Click effects: cannot read '%s', using the built-in file instead.", path)
    end
    return nil
end

function Fx:sound_path(sc)
    return self:custom(sc.file) or self:asset("cinezoom-click-v1.wav", function()
        return wav.encode_pcm16(wav.click_samples(48000), 48000)
    end)
end

-- Returns the ring image path and its width (nil for a custom image: OBS measures it)
function Fx:ripple_path(rc)
    local custom = self:custom(rc.file)
    if custom ~= nil then
        return custom, nil
    end
    local thick = math.max(1, math.floor(rc.thickness * RING_TEX / rc.size + 0.5))
    local col = rc.color -- 0xAABBGGRR: red is the low byte
    local r, g, b = col % 256, math.floor(col / 256) % 256, math.floor(col / 65536) % 256
    local name = string.format("cinezoom-ring-v1-%d-%d-%02x%02x%02x.png", RING_TEX, thick, r, g, b)
    return self:asset(name, function()
        return png.encode(RING_TEX, RING_TEX, png.ring_rgba(RING_TEX, thick, r, g, b))
    end), RING_TEX
end

---
-- Create, update or remove the parts to match the settings
---@param c table cfg.fx (see settings.lua)
function Fx:configure(c)
    self.cfg = c
    self.off = false

    if c.sound.enabled then
        local path = self:sound_path(c.sound)
        if path == nil then
            log.warn("Click sound is off: no folder is writable for the generated sound file.")
        else
            self.sound = self.sound or sound_mod.new()
            if not self.sound:configure(c.sound, path) then
                self.sound = nil
            end
        end
    elseif self.sound ~= nil then
        self.sound:destroy()
        self.sound = nil
    end

    if c.ripple.enabled then
        local path, tex = self:ripple_path(c.ripple)
        if path == nil then
            log.warn("Click ripple is off: no folder is writable for the generated ring image.")
        else
            self.ripple = self.ripple or ripple_mod.new()
            if not self.ripple:configure(c.ripple, path, tex) then
                self.ripple = nil
            end
        end
    elseif self.ripple ~= nil then
        self.ripple:destroy()
        self.ripple = nil
    end
end

---
-- True when an effect is switched on (and has not been turned off after errors)
function Fx:active()
    return not self.off and (self.sound ~= nil or self.ripple ~= nil)
end

---
-- A click was seen: at most one sound and one ripple per call. The caller applied the
-- "only inside" and "only while zoomed" filters to n. Errors are raised after both effects ran.
---@param n number Clicks since the last tick
---@param inside boolean The mouse is over the captured display
---@param cam_pt table|nil {x, y} mouse position in camera space
---@param si table Scene item controller
---@param now number
function Fx:on_click(n, inside, cam_pt, si, now)
    if n <= 0 or self.off then
        return
    end
    local err = nil
    if self.sound ~= nil then
        local ok, e = pcall(self.sound.play, self.sound)
        if not ok then err = e end
    end
    if self.ripple ~= nil and inside and cam_pt ~= nil and si.ready then
        local ok, e = pcall(function()
            if self.ripple:ensure_host(si) then
                self.ripple:spawn(cam_pt.x, cam_pt.y, now)
            end
        end)
        if not ok then err = err or e end
    end
    if err ~= nil then
        error(err, 0)
    end
end

---
-- Advance running ripples (every tick)
function Fx:tick(si, now)
    if self.ripple ~= nil and not self.off then
        self.ripple:update(si, now, si.cam_w)
    end
end

---
-- The "Test click effects" button: play the sound and show a ripple at cam_pt (the view center if nil)
---@return string message for the log
function Fx:test_click(cam_pt, si, now)
    if not self:active() then
        return "Turn on Click sound or Click ripple first."
    end
    local parts = {}
    if self.sound ~= nil then
        self.sound:play()
        parts[#parts + 1] = "played the click sound"
    end
    if self.ripple ~= nil then
        if si.ready and self.ripple:ensure_host(si) then
            local pt = cam_pt
            if pt == nil or pt.x < 0 or pt.y < 0 or pt.x > si.cam_w or pt.y > si.cam_h then
                pt = { x = si.cam_w / 2, y = si.cam_h / 2 }
                parts[#parts + 1] = "ripple at the center (the mouse is not over the zoom source)"
            else
                parts[#parts + 1] = "ripple at the mouse"
            end
            self.ripple:spawn(pt.x, pt.y, now)
        else
            parts[#parts + 1] = "no ripple (the zoom source is not ready)"
        end
    end
    return "Test click: " .. table.concat(parts, ", ")
end

---
-- Take the overlay item out of the scene it is in (the capture or scene is about to change)
function Fx:detach_host()
    if self.ripple ~= nil then
        local ok, err = pcall(self.ripple.detach_host, self.ripple)
        if not ok then
            log.debug("Click overlay detach failed: %s", tostring(err))
        end
    end
end

---
-- The scene collection is about to change (or OBS is closing): nothing of ours may stay in its scenes
function Fx:on_collection_changing()
    if self.ripple ~= nil then
        pcall(self.ripple.destroy, self.ripple)
        self.ripple = nil
    end
end

---
-- The new scene collection is loaded: bring back what OBS may have cleared
function Fx:on_collection_changed()
    if self.sound ~= nil then
        self.sound:reattach()
    end
    if self.cfg ~= nil and not self.off and self.cfg.ripple.enabled and self.ripple == nil then
        self:configure(self.cfg)
    end
end

-- Remove the generated files (never anything the user chose)
function Fx:remove_files()
    for _, a in pairs(self.assets) do
        pcall(os.remove, a.path)
    end
    self.assets = {}
end

---
-- Remove everything we created in OBS and on disk
function Fx:destroy()
    if self.ripple ~= nil then
        pcall(self.ripple.destroy, self.ripple)
        self.ripple = nil
    end
    if self.sound ~= nil then
        pcall(self.sound.destroy, self.sound)
        self.sound = nil
    end
    self:remove_files()
end

---
-- Turn the effects off after repeated errors (a settings change turns them on again)
function Fx:disable()
    self:destroy()
    self.off = true
end

---
---@param si table|nil scene item controller
---@return table lines for Diagnose
function Fx:describe(si)
    local lines = {}
    if self.sound == nil and self.ripple == nil then
        lines[#lines + 1] = self.off and "effects: turned off after errors (change a setting to try again)"
            or "effects: off (nothing created)"
    end
    local names = {}
    for name in pairs(self.assets) do
        names[#names + 1] = name
    end
    table.sort(names)
    if #names == 0 then
        lines[#lines + 1] = "asset directory: none used yet"
    end
    for _, name in ipairs(names) do
        local a = self.assets[name]
        local writable = false
        local f = io.open(a.path, "ab")
        if f ~= nil then
            writable = true
            f:close()
        end
        lines[#lines + 1] = string.format("asset: %s, %s bytes, writable: %s", a.path,
            tostring(file_size(a.path)), tostring(writable))
    end
    if self.sound ~= nil then
        for _, l in ipairs(self.sound:describe()) do lines[#lines + 1] = l end
    else
        lines[#lines + 1] = "sound: off"
    end
    if self.ripple ~= nil then
        for _, l in ipairs(self.ripple:describe(si)) do lines[#lines + 1] = l end
    else
        lines[#lines + 1] = "ripple: off"
    end
    lines[#lines + 1] = "The monitoring device is set in OBS Settings > Audio > Advanced."
    return lines
end

return M
