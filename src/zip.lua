--- A streaming zip archiver with no compression in pure lua
local zip = {}

-- Implementation references:
-- - https://blog.yaakov.online/zip64-go-big-or-go-home/
-- - https://users.cs.jmu.edu/buchhofp/forensics/formats/pkzip.html
-- - https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT


local crc32

-- If the zlib library is installed on the system, and it is by default on most,
-- it is loaded and used through LuaJIT's ffi library to significantly improve
-- performances. Otherwise the pure lua implementation is loaded.
if not pcall(function()
    local ffi = require 'ffi'

    -- On some distributions the standard zlib package provides 'libz.so' and
    -- the example on LuaJIT's website works:
    --
    --     ffi.load('z')
    --
    -- However on other distributions like debian and alpine, the standard
    -- package only provides 'libz.so.1' without the 'libz.so' symlink and
    -- ffi.load doesn't find it: an extra 'dev' package must be manually
    -- installed for the unversioned 'libz.so' symlink (on debian: 'zlib1g-dev';
    -- on alpine: 'zlib-dev').
    --
    -- Explicitly loading the package from its full soname incl. the ABI version
    -- makes it work on Debian, and should work on all systems where zlib is
    -- installed also when 'libz.so' is available.
    local zlib = ffi.load('libz.so.1')
    ffi.cdef[[
        unsigned long crc32(unsigned long crc, const char *buf, unsigned len);
    ]]

    --- Compute the ZIP-compatible CRC-32 checksum of [str].
    ---
    --- The CRC-32 checksum can be computed in several chunks by feeding the
    --- checksum of the previous chunk into [crc]:
    ---     assert(crc32('foobar') == crc32('bar', crc32('foo')))
    ---
    --- @param str string The bytes to checksum.
    --- @param crc integer|nil The initial CRC-32 value.
    --- @return integer crc The CRC-32 checksum, a 32-bit integer.
    crc32 = function(str, crc)
        return tonumber(zlib.crc32(crc or 0, str, #str))
    end
end) then
    io.stderr:write('WARNING: could not load zlib; using slow CRC32 implementation\n')
    crc32 = require('crc32').pure
end

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

--- Convert a timestamp (seconds since epoch) to DOS date and time values (each
--- packed on two bytes, cf. [1]).
---
--- [1]: https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-filetimetodosdatetime
---
--- @param ts? number Timestamp to convert. If not specified, the current time
--- is used.
--- @return number date DOS date on 2 bytes
--- @return number time DOS time on 2 bytes
local function dosts(ts)
    local now = os.date('*t', ts)

    local time = (now.sec - now.sec % 2) / 2    -- >> 1     0-4     sec/2 (0-30)
               + now.min * 2^5                  -- << 5     5-10    min (0-59)
               + now.hour * 2^11                -- << 11    11-15   hour (0-23)

    local date = now.day                        --          0-4     day (1-31)
               + now.month * 2^5                -- << 5     5-8     month (1-12)
               + (now.year - 1980) * 2^9        -- << 9     9-15    year - 1980

    return date, time
end


--------------------------------------------------------------------------------

--- Add a file to the archive.
---
--- @param zh zh Internal zip handle. The file handle generated by this method
--- will be added to `zh.directory`.
--- @param read fun(n: integer): string|nil A function returning a string of
--- length at most `n`, or `nil` if the end of the stream has been reached.
--- Typically the `file.read` function from a file handle obtained with
--- `io.open`.
--- @param path string Path of the file inside the archive. Does not need to
--- match the path on the filesystem. Must be a UTF-8 encoded string.
--- @param modts? number Timestamp of the last file modification. If not
--- provided, the current time will be used.
--- @param size? integer Size of the file. If provided, reading more bytes will
--- result in an error.
--- @param crc? integer CRC-32 of the file. If provided, the computed CRC will
--- be verified against it, and a mismatch will result in an error.
local function pack(zh, read, path, modts, size, crc)
    --- File metadata, for use later in the central directory
    --- @class fh*
    ---
    --- @field path string File name/path in the zip. Must be encoded in UTF-8.
    --- @field mtime integer File modification time, in DOS format.
    --- @field mdate integer File modification date, in DOS format.
    --- @field offset integer Byte offset of this file from the start of the stream.
    --- @field size integer|nil File size in bytes.
    --- @field crc integer|nil CRC-32 of the file.
    local fh = {
        path = path,
        offset = zh.count,
        size = size,
        crc = crc
    }

    fh.mdate, fh.mtime = dosts(modts)

    table.insert(zh.directory, fh)

    ------------------------------------------------------------------------
    -- Local file header
    -- @see APPNOTE 4.3.7 Local file header
    -- @see APPNOTE 4.4 Explanation of fields

    zh:wn(4, 0x04034b50)        -- LFH signature
    zh:wn(2, 0x2d)              -- Version needed to extract: 4.5 (ZIP64)

    -- General purpose bit flags
    -- (0-based) Flags set:
    -- Bit 3  (0x0800 BE): Data descriptor
    -- Bit 11 (0x0008 BE): Language encoding (UTF-8)
    zh:wn(2, 0x0808)            -- General purpose bit flags: DD, UTF-8

    zh:wn(2, 0)                 -- Compression method: none
    zh:wn(2, fh.mtime)          -- File modification time
    zh:wn(2, fh.mdate)          -- File modification date
    zh:wn(4, 0)                 -- CRC32; defered to data descriptor
    zh:wn(4, -1)                -- Compressed size; fixed: ZIP64
    zh:wn(4, -1)                -- Uncompressed size; fixed: ZIP64
    zh:wn(2, #fh.path)          -- File name length
    zh:wn(2, 20)                -- Extra field length: 20 (ZIP64)

    zh:wb(fh.path)              -- File name

    zh:wn(2, 1)                 -- ZIP64 extended information extra field
    zh:wn(2, 16)                -- Extra field size
    zh:wn(8, 0)                 -- Uncompressed size; fixed: defered to DD
    zh:wn(8, 0)                 -- Compressed size; fixed: defered to DD

    -- The APPNOTE Spec is extra unclear on how to handle the combination of
    -- ZIP64 and data descriptor, basically saying that the standard size fields
    -- must be both 0 (to signal the use of a data descriptor) and -1 (to signal
    -- the use of ZIP64 file size extra field). I used the interpretation from
    -- [1] to clarify this point.
    --
    -- [1]: https://github.com/sfa-siard/Zip64File/issues/5#issuecomment-427313862

    ------------------------------------------------------------------------
    -- Data

    local size = 0
    local crc
    while true do
        local data = read(8192) -- TODO: Check other sizes (e.g. 32k, 64, 128k), make it configurable
        if not data then break end

        zh:wb(data)
        size = size + #data

        if fh.size and size > fh.size then
            error(string.format(
                'file #%d %s: size mismatch: expected %d bytes, read %d already',
                #zh.directory, fh.path, fh.size, size))
        end

        crc = crc32(data, crc)
    end

    if fh.size and fh.size ~= size then
        error(string.format(
            'file #%d %s: size mismatch: expected %d bytes, read %d instead',
            #zh.directory, fh.path, fh.size, size))
    end

    if fh.crc and fh.crc ~= crc then
        error(string.format(
            'file #%d %s: CRC mismatch: expected %s, got %s instead',
            #zh.directory, fh.path,
            string.format('%08X', fh.crc), string.format('%08X', crc)))
    end

    fh.size = size
    fh.crc = crc

    ------------------------------------------------------------------------
    -- Data descriptor
    -- @see APPNOTE 4.3.9 Data descriptor

    zh:wn(4, 0x08074b50)        -- DD signature
    zh:wn(4, fh.crc)            -- CRC32
    zh:wn(8, fh.size)           -- Compressed size (ZIP64)
    zh:wn(8, fh.size)           -- Uncompressed size (ZIP64)
end


--- Write the central directory, ending the zip file. No new data should be
--- written after this method has been called.
---
--- @param zh zh Internal zip handle.
local function close(zh)
    local offset_cdfh = zh.count
    local size_cdfh = -zh.count -- size = end - start = -start + end

    for _, fh in ipairs(zh.directory) do
        ------------------------------------------------------------------------
        -- Central directory file header
        -- @see APPNOTE 4.3.12 Central directory structure

        -- If using 'version mady by' = 0x03xx (UNIX), 'External file
        -- attributes' must be set with file permissions otherwise the extracted
        -- files are unreadable, cf. https://unix.stackexchange.com/a/14727
        -- Using 0x00xx (DOS) instead allows to not have to care about that.

        zh:wn(4, 0x02014b50)    -- CDFH signature
        zh:wn(2, 0x2d)          -- Version made by: DOS/4.5
        zh:wn(2, 0x2d)          -- Version needed to extract: 4.5 (ZIP64)
        zh:wn(2, 0x0808)        -- General purpose bit flags: DD, UTF-8
        zh:wn(2, 0)             -- Compression method: none
        zh:wn(2, fh.mtime)      -- File modification time
        zh:wn(2, fh.mdate)      -- File modification date
        zh:wn(4, fh.crc)        -- CRC32
        zh:wn(4, -1)            -- Compressed size; ZIP64 constant
        zh:wn(4, -1)            -- Uncompressed size; ZIP64 constant
        zh:wn(2, #fh.path)      -- File name length
        zh:wn(2, 20)            -- Extra field length: 20 (ZIP64)
        zh:wn(2, 0)             -- File comment length
        zh:wn(2, 0)             -- Disk number start
        zh:wn(2, 0)             -- Internal file attributes: binary
        zh:wn(4, 0)             -- External file attributes
        zh:wn(4, fh.offset)     -- Relative offset of local header

        zh:wb(fh.path)          -- File name

        zh:wn(2, 1)             -- ZIP64 extended information extra field
        zh:wn(2, 16)            -- Extra field size
        zh:wn(8, fh.size)       -- Uncompressed size
        zh:wn(8, fh.size)       -- Compressed size
    end

    size_cdfh = size_cdfh + zh.count

    ----------------------------------------------------------------------------
    -- ZIP64 end of central directory record
    -- @see APPNOTE 4.3.14 Zip64 end of central directory record

    local offset_z64eocdr = zh.count

    zh:wn(4, 0x06064b50)        -- ZIP64-EOCDR signature
    zh:wn(8, 44)                -- Size of ZIP64 end of central directory record (cf. APPNOTES 4.3.14.1)
    zh:wn(2, 0x2d)              -- Version made by: DOS/4.5
    zh:wn(2, 0x2d)              -- Version needed to extract: 4.5 (ZIP64)
    zh:wn(4, 0)                 -- Number of this disk
    zh:wn(4, 0)                 -- Number of the disk with the start of the central directory
    zh:wn(8, #zh.directory)     -- Total number of entries in the central directory on this disk
    zh:wn(8, #zh.directory)     -- Total number of entries in the central directory
    zh:wn(8, size_cdfh)         -- Size of the central directory
    zh:wn(8, offset_cdfh)       -- Offset of start of central directory with respect to the starting disk number

    ----------------------------------------------------------------------------
    -- ZIP64 end of central directory record locator
    -- @see APPNOTE 4.3.15 Zip64 end of central directory locator

    zh:wn(4, 0x07064b50)        -- ZIP64-EOCDRL signature
    zh:wn(4, 0)                 -- Number of the disk with the start of the ZIP64 end of central directory
    zh:wn(8, offset_z64eocdr)   -- Relative offset of the ZIP64 end of central directory record
    zh:wn(4, 1)                 -- Total number of disks

    ----------------------------------------------------------------------------
    -- End of central directory record
    -- @see APPNOTE 4.3.16  End of central directory record
    -- @see APPNOTE 4.4.1.4

    zh:wn(4, 0x06054b50)        -- EOCDR signature
    zh:wn(2, -1)                -- Number of this disk; fixed: ZIP64
    zh:wn(2, -1)                -- Number of the disk with the start of the central directory; fixed: ZIP64
    zh:wn(2, -1)                -- Total number of entries in the central directory on this disk; fixed: ZIP64
    zh:wn(2, -1)                -- Total number of entries in the central directory; fixed: ZIP64
    zh:wn(4, -1)                -- Size of the central directory; fixed: ZIP64
    zh:wn(4, -1)                -- Offset of start of central directory with respect to the starting disk number; fixed: ZIP64
    zh:wn(2, 0)                 -- .ZIP file comment length
end


--------------------------------------------------------------------------------

--- Opens a zip stream wrapping the provided [write] function. The stream must
--- be closed with the `zip.close()` function in order to obtain a valid zip
--- file.
---
--- @param write fun(str: string): any, string? A function taking a string and
--- returning values that fith the `assert` interface: a value indicating the
--- success or failure of the operation, optionally followed by an error
--- message. Typically the `file.write` function from a file handler obtained
--- from `io.open`.
--- @return zip handle A handle to the opened stream
function zip.wrap(write)
    --- Internal zip handle, encapsulates state and internal operations.
    ---
    --- @class zh
    ---
    --- @field count integer Number of bytes written so far
    --- @field directory table Metadata of all files written
    --- @field closed boolean Whether new files can be added to the stream
    local zh = {
        count = 0,
        directory = {},
        closed = false
    }

    --- Write bytes (provided as a string) to the response body
    function zh.wb(self, str)
        if self.closed then
            error('write attempt on a closed zip handle')
        end
        self.count = self.count + #str
        assert(write(str))
    end

    --- Write a number in little-endian using the specified number of bytes.
    function zh.wn(self, nbytes, number)
        self:wb(n2le(nbytes, number))
    end


    --- Handle for the zip stream
    ---
    --- @class zip
    ---
    --- @field size integer Number of bytes written so far
    local handle = {
        size = 0
    }

    --- Write the bytes returned by [read] as a file in the zip stream.
    ---
    --- @param read fun(n: integer): string|nil A function returning a string of
    --- length at most `n`, or `nil` if the end of the stream has been reached.
    --- Typically the `file.read` function from a file handle obtained with
    --- `io.open`.
    --- @param zippath string Path of the file inside the archive. Does not need
    --- to match the path on the filesystem. Must be encoded in UTF-8.
    function handle.pack(self, read, zippath)
        pack(zh, read, zippath)
        self.size = zh.count
    end

    --- Write the central directory of the zip file, hereby closing the stream.
    --- Subsequent write operations on the stream will throw.
    function handle.close(self)
        close(zh)
        self.closed = true
        self.size = zh.count
    end

    return handle
end


--------------------------------------------------------------------------------

return zip
