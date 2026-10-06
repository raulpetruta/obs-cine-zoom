local png = require("cinezoom.assets.png")
local checksum = require("cinezoom.assets.checksum")

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Split a PNG into chunks {type, data, crc}
local function chunks(s)
    local out, i = {}, 9
    while i <= #s do
        local len = be32(s, i)
        out[#out + 1] = { type = s:sub(i + 4, i + 7), data = s:sub(i + 8, i + 7 + len), crc = be32(s, i + 8 + len) }
        i = i + 12 + len
    end
    return out
end

-- Parse a zlib stream of stored blocks: returns raw, blocks {{final, len, nlen}}, adler
local function inflate_stored(z)
    local raw, blocks, i = {}, {}, 3
    while true do
        local hdr = z:byte(i)
        local len = z:byte(i + 1) + z:byte(i + 2) * 256
        local nlen = z:byte(i + 3) + z:byte(i + 4) * 256
        blocks[#blocks + 1] = { final = hdr, len = len, nlen = nlen }
        raw[#raw + 1] = z:sub(i + 5, i + 4 + len)
        i = i + 5 + len
        if hdr == 1 then break end
    end
    return table.concat(raw), blocks, be32(z, i), i + 3 == #z
end

return function(t)
    t.test("PNG structure of a 3x2 image", function()
        local rgba = {}
        for i = 0, 23 do rgba[#rgba + 1] = string.char(i * 10) end
        rgba = table.concat(rgba)
        local s = png.encode(3, 2, rgba)
        t.eq(s:sub(1, 8), "\137PNG\r\n\26\n")
        local c = chunks(s)
        t.eq(#c, 3)
        t.eq(c[1].type, "IHDR"); t.eq(#c[1].data, 13)
        t.eq(be32(c[1].data, 1), 3); t.eq(be32(c[1].data, 5), 2)
        t.eq(c[1].data:sub(9), "\8\6\0\0\0")
        t.eq(c[1].crc, checksum.crc32("IHDR" .. c[1].data))
        t.eq(c[2].type, "IDAT")
        t.eq(c[2].crc, checksum.crc32("IDAT" .. c[2].data))
        t.eq(c[3].type, "IEND"); t.eq(#c[3].data, 0); t.eq(c[3].crc, 0xAE426082)

        local z = c[2].data
        t.eq((z:byte(1) * 256 + z:byte(2)) % 31, 0, "valid zlib header")
        local raw, blocks, adler, exact = inflate_stored(z)
        t.truthy(exact, "nothing after the adler")
        t.eq(#blocks, 1)
        t.eq(raw, "\0" .. rgba:sub(1, 12) .. "\0" .. rgba:sub(13, 24))
        t.eq(adler, checksum.adler32(raw))
    end)

    t.test("PNG of 256x256 uses several stored blocks", function()
        local s = png.encode(256, 256, string.rep("\1\2\3\4", 256 * 256))
        local z = chunks(s)[2].data
        local raw, blocks, adler = inflate_stored(z)
        t.eq(#raw, 256 * (1 + 1024))
        t.truthy(#blocks >= 5)
        for i, b in ipairs(blocks) do
            t.eq(b.len + b.nlen, 0xFFFF)
            t.truthy(b.len <= 65535)
            t.eq(b.final, i == #blocks and 1 or 0)
        end
        t.eq(adler, checksum.adler32(raw))
    end)

    t.test("ring image: transparent centre and corners, opaque on the ring, symmetric, constant colour", function()
        local tex, thick = 256, 10
        local rgba = png.ring_rgba(tex, thick, 76, 141, 255)
        t.eq(#rgba, tex * tex * 4)
        local function px(x, y) local i = (y * tex + x) * 4 + 1; return rgba:byte(i, i + 3) end
        local R = tex / 2 - 1
        local _, _, _, a = px(128, 128); t.eq(a, 0, "centre")
        _, _, _, a = px(0, 0); t.eq(a, 0, "corner")
        _, _, _, a = px(255, 255); t.eq(a, 0, "corner")
        -- on the horizontal axis at radius R - thick/2 (pixel x is at x + 0.5 - 128 from the centre)
        _, _, _, a = px(128 + math.floor(R - thick / 2), 128); t.eq(a, 255, "on the ring")
        for y = 0, tex - 1, 7 do
            for x = 0, tex - 1, 5 do
                local r, g, b, aa = px(x, y)
                t.eq(r, 76); t.eq(g, 141); t.eq(b, 255)
                local _, _, _, mx = px(tex - 1 - x, y)
                local _, _, _, my = px(x, tex - 1 - y)
                t.eq(aa, mx, "mirror x"); t.eq(aa, my, "mirror y")
            end
        end
    end)
end
