local wav = require("cinezoom.assets.wav")

local function le(s, i, n)
    local v = 0
    for k = n - 1, 0, -1 do v = v * 256 + s:byte(i + k) end
    return v
end

return function(t)
    t.test("WAV header fields", function()
        local s = wav.encode_pcm16({ 0, 1, -1, 32767, -32768 }, 48000)
        t.eq(s:sub(1, 4), "RIFF"); t.eq(le(s, 5, 4), 36 + 10); t.eq(s:sub(9, 12), "WAVE")
        t.eq(s:sub(13, 16), "fmt "); t.eq(le(s, 17, 4), 16); t.eq(le(s, 21, 2), 1); t.eq(le(s, 23, 2), 1)
        t.eq(le(s, 25, 4), 48000); t.eq(le(s, 29, 4), 96000); t.eq(le(s, 33, 2), 2); t.eq(le(s, 35, 2), 16)
        t.eq(s:sub(37, 40), "data"); t.eq(le(s, 41, 4), 10)
        t.eq(#s, 44 + 10)
        t.eq(le(s, 45, 2), 0); t.eq(le(s, 47, 2), 1); t.eq(le(s, 49, 2), 65535)
        t.eq(le(s, 51, 2), 32767); t.eq(le(s, 53, 2), 32768)
    end)

    t.test("click sound length, level and determinism", function()
        local samples = wav.click_samples(48000)
        t.eq(#samples, math.floor(48000 * 0.04))
        local peak = 0
        for _, v in ipairs(samples) do peak = math.max(peak, math.abs(v)) end
        t.truthy(peak >= 8000 and peak <= 32767, "peak " .. peak)
        t.truthy(math.abs(samples[1]) < 100, "starts near silence")
        t.truthy(math.abs(samples[#samples]) < 200, "ends near silence")
        local a, b = wav.encode_pcm16(samples, 48000), wav.encode_pcm16(wav.click_samples(48000), 48000)
        t.eq(a, b, "identical bytes")
        t.eq(le(a, 41, 4), 2 * math.floor(48000 * 0.04))
    end)
end
