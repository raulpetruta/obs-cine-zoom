local checksum = require("cinezoom.assets.checksum")

return function(t)
    t.test("crc32 known values", function()
        t.eq(checksum.crc32("123456789"), 0xCBF43926)
        t.eq(checksum.crc32(""), 0)
        t.eq(checksum.crc32("The quick brown fox jumps over the lazy dog"), 0x414FA339)
        t.eq(checksum.crc32("IEND"), 0xAE426082)
    end)

    t.test("adler32 known values", function()
        t.eq(checksum.adler32("Wikipedia"), 0x11E60398)
        t.eq(checksum.adler32(""), 1)
    end)

    t.test("chunked results equal one-shot results", function()
        local s = "The quick brown fox jumps over the lazy dog"
        t.eq(checksum.crc32(s:sub(20), checksum.crc32(s:sub(1, 19))), checksum.crc32(s))
        t.eq(checksum.adler32(s:sub(20), checksum.adler32(s:sub(1, 19))), checksum.adler32(s))
        local big = string.rep("abcdefghij", 3000)
        t.eq(checksum.adler32(big:sub(10001), checksum.adler32(big:sub(1, 10000))), checksum.adler32(big))
    end)
end
