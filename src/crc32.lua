-- TODO: Investigate possible improvements based on https://create.stephan-brumme.com/crc32/
-- TODO: Investigate performance improvements from using LuaJIT's 'bit' module

--- @alias byte integer Integer values 0-255


--- Functions to compute the CRC-32 checksum used in ZIP files.
local crc32 = {}

--- Decompose a 32-bit integer into its byte components.
--- @param n integer A 32-bit integer. Larger integers are truncated.
--- @return byte b0 Least significant byte
--- @return byte b1 Second byte
--- @return byte b2 Third byte
--- @return byte b3 Most significant byte
local function i2b(n)
    local b0, b1, b2, b3
    b0 = n % 256
    n = (n - b0) / 256
    b1 = n % 256
    n = (n - b1) / 256
    b2 = n % 256
    n = (n - b2) / 256
    b3 = n % 256
    return b0, b1, b2, b3
end

--- Build a 32-bit integer from its byte components
--- @return byte b0 Least significant byte
--- @return byte b1 Second byte
--- @return byte b2 Third byte
--- @return byte b3 Most significant byte
--- @return integer n A 32-bit integer.
local function b2i(b0, b1, b2, b3)
    return b0 + b1 * 2^8 + b2 * 2^16 + b3 * 2^24
end

--- Bitwise xor. The xor operator `~` is not available in lua 5.1.
--- @param a integer Left operand
--- @param b integer Right operand
--- @return integer `a ~ b`
--- @see SO https://stackoverflow.com/a/25594410
local function xor(a, b)
    local p, c = 1, 0
    while a > 0 and b > 0 do
        local ra, rb = a % 2, b % 2
        if ra ~= rb then c = c + p end
        a, b, p = (a - ra) / 2, (b - rb) / 2, p * 2
    end
    if a < b then a = b end
    while a > 0 do
        local ra = a % 2
        if ra > 0 then c = c + p end
        a, p = (a - ra) / 2, p * 2
    end
    return c
end


-- Bitwise xor lookup table for all byte pairs.
-- Improves performances in the absence of a native xor operator.
local _xor = {}
for i = 0, 255 do
    local t = {}
    _xor[i] = t
    for j = 0, 255 do
        t[j] = xor(i, j)
    end
end

-- Precomputed CRC-32 lookup table with polynomial 0xdebb20e3 (ZIP magic
-- number).
--
-- Notes:
-- - 0xedb88320 == 0xffffffff ^ bit_reverse(0xdebb20e3)
-- - Operator `&` not available in lua 5.1: n & 1 == n % 2
-- - Operator `>>` not available in lua 5.1: n >> 1 == math.floor(n / 2)
-- - math.floor is avoided by substracting 1 from odd numbers
local _crc0, _crc1, _crc2, _crc3 = {}, {}, {}, {}
for i = 0, 255 do
    local crc = i
    for _ = 0, 7 do
        -- crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320
        crc = (crc % 2 == 0) and (crc / 2) or xor((crc - 1) / 2, 0xedb88320)
    end
    _crc0[i], _crc1[i], _crc2[i], _crc3[i] = i2b(crc)
end


--- Compute the ZIP-compatible CRC-32 checksum of [str], implemented in pure lua
--- without external dependencies.
---
--- The CRC-32 checksum can be computed in several chunks by feeding the
--- checksum of the previous chunk into [crc]:
---     assert(crc32('foobar') == crc32('bar', crc32('foo')))
---
--- @param str string The bytes to checksum.
--- @param crc integer|nil The initial CRC-32 value.
--- @return integer crc The CRC-32 checksum, a 32-bit integer.
function crc32.pure(str, crc)
    crc = (crc or 0) % 2^32

    -- Working on individual bytes allows to use small-ish lookup tables for the
    -- xor operation; lookup tables being faster than computing the xor of two
    -- integers using a function in a tight loop.
    local c0, c1, c2, c3 = i2b(crc)

    -- crc = crc ^ 0xffffffff
    c0, c1, c2, c3 = _xor[255][c0], _xor[255][c1], _xor[255][c2], _xor[255][c3]

    -- foreach byte in str: crc = _crc[(crc ^ byte) & 0xff] ^ (crc >> 8)
    for i=1, #str do
        local byte = string.byte(str, i)
        local k = _xor[c0][byte] -- (crc ^ byte) & 0xff == (crc & 0xff) ^ byte
        c0 = _xor[_crc0[k]][c1]
        c1 = _xor[_crc1[k]][c2]
        c2 = _xor[_crc2[k]][c3]
        c3 =      _crc3[k]      -- n ^ 0 == n
    end

    -- crc = crc ^ 0xffffffff
    c0, c1, c2, c3 = _xor[255][c0], _xor[255][c1], _xor[255][c2], _xor[255][c3]

    return b2i(c0, c1, c2, c3)
end


return crc32
