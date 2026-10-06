-- Minimal PNG writer (8-bit RGBA, no compression: stored deflate blocks) and the ripple ring image.
-- OBS reads the file with its normal image loader, so the output only has to be a valid PNG.
local checksum = require("cinezoom.assets.checksum")

local M = {}

local SIGNATURE = "\137PNG\r\n\26\n"
local MAX_BLOCK = 65535

local function u32be(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256, v % 256)
end

local function chunk(kind, data)
    return u32be(#data) .. kind .. data .. u32be(checksum.crc32(data, checksum.crc32(kind)))
end

-- zlib stream made of stored (uncompressed) deflate blocks
local function zlib_stored(raw)
    local out = { "\120\1" } -- 0x78 0x01: deflate, 32K window, no preset dictionary, fastest level
    local n = #raw
    local pos = 1
    repeat
        local len = math.min(MAX_BLOCK, n - pos + 1)
        local final = (pos + len > n) and 1 or 0
        local nlen = 65535 - len
        out[#out + 1] = string.char(final, len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256))
        out[#out + 1] = raw:sub(pos, pos + len - 1)
        pos = pos + len
    until pos > n
    out[#out + 1] = u32be(checksum.adler32(raw))
    return table.concat(out)
end

---
-- Encode an image as PNG
---@param w number
---@param h number
---@param rgba string w*h*4 bytes, straight (non-premultiplied) alpha
---@return string
function M.encode(w, h, rgba)
    assert(#rgba == w * h * 4, "rgba must be w*h*4 bytes")
    local rows = {}
    local stride = w * 4
    for y = 0, h - 1 do
        rows[#rows + 1] = "\0" .. rgba:sub(y * stride + 1, (y + 1) * stride) -- filter type 0 (none)
    end
    local ihdr = u32be(w) .. u32be(h) .. "\8\6\0\0\0" -- 8 bit, RGBA, deflate, no filter, no interlace
    return SIGNATURE .. chunk("IHDR", ihdr) .. chunk("IDAT", zlib_stored(table.concat(rows))) .. chunk("IEND", "")
end

---
-- Anti-aliased ring, tex x tex pixels. The colour is the same everywhere (also where the
-- ring is transparent) so scaling the image never bleeds a different colour in.
---@param tex number Image size in pixels
---@param thick number Ring thickness in pixels (of the image)
---@return string rgba
function M.ring_rgba(tex, thick, r, g, b)
    local c = tex / 2
    local outer = tex / 2 - 1
    local inner = outer - thick
    local rgb = string.char(r, g, b)
    local out = {}
    for y = 0, tex - 1 do
        local dy = y + 0.5 - c
        for x = 0, tex - 1 do
            local dx = x + 0.5 - c
            local d = math.sqrt(dx * dx + dy * dy)
            local a = math.max(0, math.min(1, outer - d + 0.5)) * math.max(0, math.min(1, d - inner + 0.5))
            out[#out + 1] = rgb .. string.char(math.floor(a * 255 + 0.5))
        end
    end
    return table.concat(out)
end

return M
