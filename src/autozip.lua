local lfs = require 'lfs'
local ngx = require 'ngx'
local zip = require 'zip'

local autozip = {}

---
-- Return an iterator which walks through a directory tree starting at
-- `startdir`.
--
-- The optional argument `filter` is a function that is applied to each
-- element determining whether it will be yielded, and for a directory
-- additionally whether it will be recursed into.
--
-- The iterator returns `(rpath, name, mode, islink)` where
-- - `rpath` is the path the element *relative to `startdir`*
-- - `name` is the name of the element
-- - `mode` corresponds to the element's type (see lfs.attributes)
-- - `islink` returns true iff the element is a symlink. Note that when `islink`
--   is true, `mode` is the mode of the symlink's target.
--
-- The `filter` argument is a function `(path, name, mode, islink) -> bool`
-- where `path` is the path to the element (note: contrary to the iterator, it
-- is *not* relative to `startdir`) and the other parameters are the same as for
-- the iterator. If the filter function returns true, the element is yielded,
-- and if the element is a directory it will be recursed into.
local function walk(startdir, filter)
    if lfs.attributes(startdir, 'mode') ~= 'directory' then
        error('startdir is not a directory: ' .. startdir)
    end

    return coroutine.wrap(function()
        -- Ensure startdir path ends with a slash, as it makes it easier to
        -- handle the case of the root path '/'
        local startdir = startdir:gsub('[^/]$', '%0/')

        -- Directories to visit
        -- Paths relative to startdir, must end with '/' (except for the
        -- initialization value: an empty string denoting startdir itself).
        local pending = { '' }

        while #pending > 0 do
            local parent = table.remove(pending)

            for fname in lfs.dir(startdir .. parent) do
                if fname ~= '.' and fname ~= '..' then
                    local rpath = parent .. fname
                    local path =  startdir .. rpath
                    local mode = lfs.attributes(path, 'mode')
                    local islink = lfs.symlinkattributes(path, 'mode') == 'link'

                    if not filter or filter(path, fname, mode, islink) then
                        if mode == 'directory' then
                            table.insert(pending, rpath .. '/')
                        end
                        coroutine.yield(rpath, fname, mode, islink)
                    end
                end
            end
        end
    end)
end

---
-- Escape `uri` as a full URI, i.e. preserving the directory separators.
-- This should perform the same as `ngx.escape_uri` with `type = 0`, which is
-- available since http-lua 0.10.16 (but at the time of writing, I am still
-- using version 0.10.13 of the module).
--
-- TODO: Replace calls to this method with `ngx.escape_uri(uri, 0)` when it
-- becomes available.
local function escape_uri(uri)
    return uri:gsub('[^-._~%w/]', function(c)
        return string.format('%%%02X', c:byte())
    end)
end

--- Print in the response body the list of files in a directory tree, using the
--- format required by mod_zip.
---
--- @param fsroot string Path of the directory in the filesystem.
--- @param uriroot? string Path of the directory in the URL. Default: `'/'`.
function autozip.mod_zip_filelist(fsroot, uriroot)
    local filter = function(_, name, mode, islink)
        if islink then return false end -- For security reasons
        if name:sub(1, 1) == '.' then return false end -- Hidden files and dirs
        return mode == 'file' or mode == 'directory'
    end

    -- Ensure fsroot ends with a slash
    fsroot = fsroot:gsub('[^/]$', '%0/')

    -- Set uriroot if not set and ensure it ends with a slash
    uriroot = (uriroot or '/'):gsub('[^/]$', '%0/')

    for rpath, _, mode in walk(fsroot, filter) do
        -- For mod_zip we don't care about directories, only files
        if mode == 'file' then
            ngx.print(string.format(
                '- %d %s %s\n', -- TODO: Does mod_zip need \r\n or just \n?
                lfs.attributes(fsroot .. rpath, 'size'),
                -- Percent-encode preserving dir separators
                escape_uri(uriroot .. rpath),
                -- Sanitize path: newlines would mess with mod_zip
                rpath:gsub('\n', '_'):gsub('%c', '')
            ))
        end
    end
end

--- Write as a zip file in the response body the content of the directory
--- [fsroot].
---
--- @param fsroot string Path on the filesystem of a directory to zip. The paths
--- in the zip will be relative to that directory.
function autozip.dir(fsroot)
    local filter = function(_, name, mode, islink)
        if islink then return false end -- For security reasons
        if name:sub(1, 1) == '.' then return false end -- Hidden files and dirs
        return mode == 'file' or mode == 'directory'
    end

    -- Ensure fsroot ends with a slash
    fsroot = fsroot:gsub('[^/]$', '%0/')

    local zh = zip.wrap(function(str) return ngx.print(str) end)

    for rpath, _, mode in walk(fsroot, filter) do
        -- For mod_zip we don't care about directories, only files
        if mode == 'file' then
            local fh = assert(io.open(fsroot .. rpath, 'rb'))
            zh:pack(function(n) return fh:read(n) end, rpath)
            fh:close()
        end
    end

    zh:close()
end


return autozip


-- EXAMPLE USE
--------------------------------------------------------------------------------
-- filelist
-- ========
--
-- Copy this mod_zip.lua file somewhere on nginx' lua package path.
--
-- If you put it somewhere else, say under /etc/nginx/lua/, you must adapt the
-- package path using the following directive in the `http` context:
--
--     lua_package_path ';;/etc/nginx/lua/?.lua';
--
-- You can then generate the filelist in your upstream server using the
-- following snippet:
--
-- ```
-- location /zip/ {
--     content_by_lua_block {
--         local mz = require 'mod_zip'
--
--         -- Get the filesystem path and the URI path where the files are
--         -- located.
--         -- Note: ngx.var.uri always starts with a '/'
--         local fsroot = ngx.var.document_root:gsub('/$', '') .. ngx.var.uri
--         local uriroot = ngx.var.uri
--
--         -- Trigger mod_zip in the downstream server
--         ngx.header.x_archive_files = 'zip'
--
--         -- The Content-Disposition header could also be used to propose a
--         -- filename, but it is a bit tricky. If the filename is not
--         -- specified, the browser should use the request's URL to determine
--         -- it.
--         ngx.header.content_disposition = 'attachment'
--
--         -- Write in the body the file list in the format required by mod_zip
--         mz.filelist(fsroot, uriroot)
--     }
-- }
-- ```
--
-- This technique can be used within the same nginx instance by using a second
-- `server` directive to act as an upstream, see [1].
--
-- It might be possible to generate the list without using an upstream server by
-- using named paths; although this has not been tested. Using the following
-- configuration, mod_zip should be triggered when the `download` request
-- parameter is set:
--
-- ```
-- location / {
--     error_page 418 @autozip;
--
--     if ($args ~ (^|&)download(&|$)) {
--         return 418;
--     }
--
--     # ... other directives, e.g. to generate an autoindex
-- }
--
-- location @autozip {
--     content_by_lua_block {
--         -- Use the same script as above
--     }
-- }
-- ```
--
--
-- [1]: https://github.com/evanmiller/mod_zip/blob/master/t/nginx.conf
