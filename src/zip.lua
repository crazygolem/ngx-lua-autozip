--- A streaming zip archiver with no compression in pure lua

local crc = require 'crc32'

local zip = {}

--- Convert a lua integer to its little endian representation on the specified
--- number of bytes.
---
--- If [nbytes] is smaller than the number of bytes required to encode [number],
--- [number] will be truncated to its [nbytes] lowest bytes. If [nbytes] is
--- larger, the output will be padded with zeroes on the most significant bytes.
---
--- The ZIP specification requires a little-endian representation for most
--- numbers.
---
--- @param nbytes integer Number of bytes to use for the output.
--- @param number integer Integer to convert.
--- @return string bytes Byte representation of [number] in little-endian.
local function n2le(nbytes, number)
    local out = {}
    for _ = 1, nbytes do
        local byte = number % 256
        table.insert(out, string.char(byte))
        number = (number - byte) / 256
    end
    return table.concat(out)
end


--- Write bytes (provided as a string) to the response body
local function wb(str)
    -- TODO
end

--- Write a number in little-endian using the specified number of bytes.
local function wn(nbytes, number)
    wb(n2le(nbytes, number))
end

-- Return the number of written bytes
local function pos()
    -- TODO
end

-- https://blog.yaakov.online/zip64-go-big-or-go-home/
-- https://users.cs.jmu.edu/buchhofp/forensics/formats/pkzip.html
-- https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
function zip.pack(...)
    local files = table.pack(...)

    -- Metadata of all packed files, used to build the central directory
    local metas = {}

    for _, f in ipairs(files) do
        -- File metadata, for use later in the central directory
        local fh = {}
        table.insert(metas, fh)

        fh.reader = nil                 -- TODO
        fh.path = nil                   -- File name/path TODO: Sanitize filename (?), convert '\' to '/', ensure UTF-8
        fh.lpath = string.len(fh.path)  -- Length of the file name
        fh.mtime = 0                    -- TODO
        fh.mdate = 0                    -- TODO
        fh.offset = pos()               -- Offset of the LFH
        fh.size = nil                   -- File size in bytes
        fh.crc32 = nil                  -- CRC-32 of the file

        ------------------------------------------------------------------------
        -- Local file header
        -- @see APPNOTE 4.3.7 Local file header
        -- @see APPNOTE 4.4 Explanation of fields

        wn(4, 0x04034b50)           -- LFH signature
        wn(2, 0x2d)                 -- Version needed to extract: 4.5 (ZIP64)

        -- General purpose bit flags
        -- (0-based) Flags set:
        -- Bit 3  (0x0800 BE): Data descriptor
        -- Bit 11 (0x0008 BE): Language encoding (UTF-8)
        wn(2, 0x0808)               -- General purpose bit flags: DD, UTF-8

        wn(2, 0)                    -- Compression method: none
        wn(2, fh.mtime)             -- File modification time
        wn(2, fh.mdate)             -- File modification date
        wn(4, 0)                    -- CRC32; defered to data descriptor
        wn(4, -1)                   -- Compressed size; fixed: ZIP64
        wn(4, -1)                   -- Uncompressed size; fixed: ZIP64
        wn(2, fh.lpath)             -- File name length
        wn(2, 20)                   -- Extra field length: 20 (ZIP64)

        wb(fh.path)                 -- File name

        wn(2, 1)                    -- ZIP64 extended information extra field
        wn(2, 16)                   -- Extra field size
        wn(8, 0)                    -- Uncompressed size; fixed: defered to DD
        wn(8, 0)                    -- Compressed size; fixed: defered to DD

        -- The APPNOTE Spec is extra unclear on how to handle the combination of
        -- ZIP64 and data descriptor, basically saying that the standard size
        -- fields must be both 0 and -1. I used the interpretation from [1] to
        -- clarify this point.
        --
        -- [1]: https://github.com/sfa-siard/Zip64File/issues/5#issuecomment-427313862

        ------------------------------------------------------------------------
        -- Data

        local size = 0
        local crc32
        while true do
            local data = fh.reader:read(8192)
            if not data then break end
            wb(data)
            size = size + #data
            crc32 = crc.crc32(data, crc32)
        end
        -- TODO: If known, verify instead of set
        fh.size = size
        fh.crc32 = crc32

        ------------------------------------------------------------------------
        -- Data descriptor
        -- @see APPNOTE 4.3.9 Data descriptor

        wn(4, 0x08074b50)           -- DD signature
        wn(4, fh.crc32)             -- CRC32
        wn(8, fh.size)              -- Compressed size (ZIP64)
        wn(8, fh.size)              -- Uncompressed size (ZIP64)
    end

    local offset_cdfh = pos()
    local size_cdfh = 0

    for _, f in ipairs(metas) do
        -- Fixed-size fields (66 bytes) + variable-size fields
        size_cdfh = size_cdfh + 66 + f.lpath

        ------------------------------------------------------------------------
        -- Central directory file header
        -- @see 4.3.12 Central directory structure
        -- If using 'version mady by' = 0x03xx (UNIX), 'External file
        -- attributes' must be set with file permissions otherwise the extracted
        -- files are unreadable, cf. https://unix.stackexchange.com/a/14727

        wn(4, 0x02014b50)           -- CDFH signature
        wn(2, 0x2d)                 -- Version made by: DOS/4.5
        wn(2, 0x2d)                 -- Version needed to extract: 4.5 (ZIP64)
        wn(2, 0x0808)               -- General purpose bit flags: DD, UTF-8
        wn(2, 0)                    -- Compression method: none
        wn(2, f.mtime)              -- File modification time
        wn(2, f.mdate)              -- File modification date
        wn(4, f.crc32)              -- CRC32
        wn(4, -1)                   -- Compressed size; ZIP64 constant
        wn(4, -1)                   -- Uncompressed size; ZIP64 constant
        wn(2, f.lpath)              -- File name length
        wn(2, 20)                   -- Extra field length: 20 (ZIP64)
        wn(2, 0)                    -- File comment length
        wn(2, 0)                    -- Disk number start
        wn(2, 0)                    -- Internal file attributes: binary
        wn(4, 0)                    -- External file attributes
        wn(4, f.offset)             -- Relative offset of local header

        wb(f.path)                  -- File name

        wn(2, 1)                    -- ZIP64 extended information extra field
        wn(2, 16)                   -- Extra field size
        wn(8, f.size)               -- Uncompressed size
        wn(8, f.size)               -- Compressed size
    end

    ----------------------------------------------------------------------------
    -- ZIP64 end of central directory record
    -- @see 4.3.14 Zip64 end of central directory record

    local offset_z64eocdr = pos()

    wn(4, 0x06064b50)               -- ZIP64-EOCDR signature
    wn(8, 44)                       -- Size of ZIP64 end of central directory record (cf. APPNOTES 4.3.14.1)
    wn(2, 0x2d)                     -- Version made by: DOS/4.5
    wn(2, 0x2d)                     -- Version needed to extract: 4.5 (ZIP64)
    wn(4, 0)                        -- Number of this disk
    wn(4, 0)                        -- Number of the disk with the start of the central directory
    wn(8, #metas)                   -- Total number of entries in the central directory on this disk
    wn(8, #metas)                   -- Total number of entries in the central directory
    wn(8, size_cdfh)                -- Size of the central directory
    wn(8, offset_cdfh)              -- Offset of start of central directory with respect to the starting disk number

    ----------------------------------------------------------------------------
    -- ZIP64 end of central directory record locator

    wn(4, 0x07064b50)               -- ZIP64-EOCDRL signature
    wn(4, 0)                        -- Number of the disk with the start of the ZIP64 end of central directory
    wn(8, offset_z64eocdr)          -- Relative offset of the ZIP64 end of central directory record
    wn(4, 1)                        -- Total number of disks

    ----------------------------------------------------------------------------
    -- End of central directory record

    wn(4, 0x06054b50)               -- EOCDR signature
    wn(2, -1)                       -- Number of this disk; fixed: ZIP64
    wn(2, -1)                       -- Number of the disk with the start of the central directory; fixed: ZIP64
    wn(2, -1)                       -- Total number of entries in the central directory on this disk; fixed: ZIP64
    wn(2, -1)                       -- Total number of entries in the central directory; fixed: ZIP64
    wn(4, -1)                       -- Size of the central directory; fixed: ZIP64
    wn(4, -1)                       -- Offset of start of central directory with respect to the starting disk number; fixed: ZIP64
    wn(2, 0)                        -- .ZIP file comment length
end


return zip
