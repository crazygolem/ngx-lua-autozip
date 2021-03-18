--- The autozip module assembles ZIP archives on the fly and streams the result
--- to the client.
---
--- It is meant to complement nginx' autoindex module by allowing users to
--- download easily the content of the directories they browse.
---
--- It was inspired by the mod_zip nginx module, but has the goal to provide a
--- saner API, notably in not requiring an upstream server to generate a list of
--- local files.
---
--- The only dependency that is not implemented purely in lua is `lfs`, usually
--- available in the distribution's package manager under the name
--- *lua-filesystem*.
local autozip = {}


local lfs = require 'lfs'
local ngx = require 'ngx'
local zip = require 'zip'

--- Return an iterator which walks through a directory tree and yields on each
--- element (e.g. file, directory) encountered along the way, or optionally only
--- those allowed by [filter].
---
--- @param startdir string Directory on the filesystem where the walk will start
--- @param filter? fun(path: string, fname: string, mode:string, islink: boolean)
--- Function that is applied to each element determining whether it will be
--- yielded, and for a directory additionally whether it will be recursed into.
--- The arguments are: [path] is the absolute path of the element, incl.
--- filename; [fname] is the filename of the element; [mode] is the element's
--- type (see `lfs.attributes`); and [islink] is `true` iff the element is a
--- symlink (in which case [mode] is the type of the symlink's target).
--- @return string rpath, string fname, string mode, boolean islink [rpath] is
--- the path of the element relative to [startdir], incl. filename; [fname] is
--- the element's filename; [mode] is the element's type (see `lfs.attributes`);
--- and [islink] is true iff the element is a symlink (in which case [mode] is
--- the type of the symlink's target)
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
--- Escape [uri] as a full URI, i.e. preserving the directory separators.
--- This should perform the same as `ngx.escape_uri` with `type = 0`, which is
--- available since http-lua 0.10.16 (but at the time of writing, I am still
--- using version 0.10.13 of the module).
---
--- TODO Replace calls to this method with `ngx.escape_uri(uri, 0)` when it
--- becomes available.
---
--- @param uri string The URI to escape
--- @return string escaped The escaped URI
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

--- Attempt to serve a directory by zipping it on the fly, in conjunction with
--- a small `location` configuration snippet that can be inserted in a `server`
--- directive or nested in another `location` directive:
---
---     location ~ \.zip$ {
---       try_files $uri $uri/ @try_zip;
---     }
---
--- and the corresponding named location that in turn calls this function:
---
---     location @try_zip {
---         content_by_lua_block {
---             local autozip = require 'autozip'
---             autozip.try_zip('=404')
---         }
---     }
---
--- With the above configuration, autozip is triggered when all of the following
--- conditions apply:
--- 1. The URL requests a ZIP file (based on the extension)
--- 2. There is no file at that location
--- 3. There is no directory (with a name that ends in '.zip') either
--- 4. There is a directory with the same name but without the extension (i.e.
---    the extension is "virtual")
---
--- @param fallback string A URI, named location or code, following the syntax
--- (and purpose) of nginx' fallback argument to `try_files`.
function autozip.try_zip(fallback)
    -- Make sure empty directory names are not matched, otherwise it could
    -- lead to the parent directory getting zipped (e.g. with '/foo/.zip')
    local uriroot, dirname = ngx.var.uri:match('^(.*/([^/]+))%.zip$')

    if not uriroot then
      return ngx.exec(fallback)
    end

    -- Hidden directories anywhere in the path should not be served
    if uriroot:find('/%.') then
      return ngx.exec(fallback)
    end

    -- With nginx the uri always starts with '/'
    local fsroot = ngx.var.document_root:gsub('/$', '') .. uriroot

    -- Ensure that a directory is being served, not a file or something else.
    -- Note: As written symlinks are allowed as the root directory, but none
    -- below it will be followed.
    if lfs.attributes(fsroot, 'mode') ~= 'directory' then
      return ngx.exec(fallback)
    end

    -- The Content-Disposition header could be used to also suggest a filename,
    -- but support is somewhat flacky. It is best to let the user-agent handle
    -- this by having a URL that ends with the suggested filename.
    ngx.header.content_disposition = 'attachment'
    ngx.header.content_type = 'application/zip'
    autozip.dir(fsroot)
end


return autozip
