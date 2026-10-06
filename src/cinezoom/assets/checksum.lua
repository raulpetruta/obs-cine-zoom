-- CRC-32 (PNG chunks) and Adler-32 (zlib stream), pure Lua on LuaJIT's bit library.
-- Both return unsigned numbers and can be fed in pieces by passing the previous result back.
local bit = require("bit")

local M = {}

local TABLE = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then
            c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
        else
            c = bit.rshift(c, 1)
        end
    end
    TABLE[i] = c
end

local function unsigned(v)
    if v < 0 then
        v = v + 2 ^ 32
    end
    return v
end

---
-- CRC-32 (polynomial 0xEDB88320). Pass the previous result as `crc` to continue a checksum.
---@param s string
---@param crc number|nil
---@return number
function M.crc32(s, crc)
    local c = bit.bnot(crc or 0)
    for i = 1, #s do
        c = bit.bxor(TABLE[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return unsigned(bit.bnot(c))
end

---
-- Adler-32. Pass the previous result as `a` to continue a checksum.
---@param s string
---@param a number|nil
---@return number
function M.adler32(s, a)
    a = a or 1
    local s1, s2 = a % 65536, math.floor(a / 65536)
    for i = 1, #s do
        s1 = (s1 + s:byte(i)) % 65521
        s2 = (s2 + s1) % 65521
    end
    return s2 * 65536 + s1
end

return M
