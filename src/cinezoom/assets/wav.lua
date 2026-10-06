-- Mono 16-bit PCM WAV writer and the synthesized click sound.
local M = {}

local function u16le(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

---
-- Encode samples as a WAV file
---@param samples number[] Integers in -32768..32767
---@param rate number Samples per second
---@return string
function M.encode_pcm16(samples, rate)
    local n = #samples
    local body = {}
    for i = 1, n do
        local v = samples[i]
        if v < 0 then
            v = v + 65536
        end
        body[i] = u16le(v)
    end
    return table.concat({
        "RIFF", u32le(36 + n * 2), "WAVE",
        "fmt ", u32le(16), u16le(1), u16le(1), u32le(rate), u32le(rate * 2), u16le(2), u16le(16),
        "data", u32le(n * 2), table.concat(body),
    })
end

---
-- A short, crisp click: two sine partials and a burst of noise under a fast attack, 6 ms decay.
-- The noise is a fixed Park-Miller sequence so the file is identical on every run.
---@param rate number|nil Samples per second (default 48000)
---@return number[] samples Integers in -32768..32767
function M.click_samples(rate)
    rate = rate or 48000
    local n = math.floor(rate * 0.040)
    local x = 1
    local raw, peak = {}, 0
    for i = 0, n - 1 do
        local t = i / rate
        x = x * 16807 % 2147483647
        local noise = x / 2147483647 * 2 - 1
        local env = (1 - math.exp(-t / 0.0005)) * math.exp(-t / 0.006)
        local v = env * (0.55 * math.sin(2 * math.pi * 2400 * t) + 0.25 * math.sin(2 * math.pi * 5200 * t) + 0.2 * noise)
        raw[i + 1] = v
        peak = math.max(peak, math.abs(v))
    end
    local out = {}
    local gain = peak > 0 and 0.8 / peak or 0
    for i = 1, n do
        out[i] = math.floor(raw[i] * gain * 32767 + 0.5)
    end
    return out
end

return M
