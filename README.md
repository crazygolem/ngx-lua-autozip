# ngx-lua-autozip (autozip for NGINX in Lua)

Lua module for nginx/openresty to stream zip archives assembled on the fly.

The only dependendencies of autozip are either pure lua modules themselves and
small enough to be included in the project, the `lfs` (`lua-filesystem`) module
which seems to be widely available in package managers around the globe, and
the modules provided by the target environment, namely the `ngx` module
provided by openresty and possibly in the future dependencies on the modules
included in LuaJIT as it is the interpreter used by openresty.

## Why autozip

Autozip can be used when [mod_zip] is not available out of the box or via your
operating system's package manager (and you don't want to recompile nginx
yourself), but nginx' lua module is.

It can be used to complement your autoindex (ideally with a custom stylesheet)
when you want to provide visitors the convenience of both a directory to explore
and a zip of said directory to download, but don't want to waste twice the space
for it.

Another reason to use autozip is when you could use mod_zip but you don't have
an upstream server telling it which files to serve, or don't want to set up one
to serve local files (ideally mod_zip should be able to figure out for itself
and with minimal configuration which files can be zipped locally). Or if you
think that any upstream sending the right magic header triggering mod_zip is a
bit too much, and you would prefer an opt-in mechanism instead.

However if you still want to use mod_zip (and there are reasons you might want
to, the least of them not being performance), autozip has a function to output
the list of files required by mod_zip: check out `autozip.mod_zip_filelist`.

## Why not autozip

It is painfully slow. And it uses a lot of CPU. Those two are related. Please
open tickets or contribute if you know how to improve the situation.

It is not well tested. It is not super complex, but a few tests here and there
wouldn't hurt. Dear reader, you are welcome to help with that.

It doesn't have the zip feature that you need. The selected zip feature set is
pretty much on point for the target usage: zipping on the fly potentially large
directories and files, no need for compression as most file formats would
handle that better, minimal external dependencies. Unless there is a clear
benefit at a relatively low cost, it probably won't land in this project.

There are probably many other reasons. If you feel like it, you can add some to
this list.


# Usage & Examples

Copy the lua files somewhere on nginx' lua package path.

If you copy them somewhere else, say under `/home/nginx/lua/`, you must adapt
the package path using the following directive in the `http` context of your
site or nginx' configuration:

    lua_package_path '/home/nginx/lua/?.lua;;';

You can then require and use `autozip` to fit your situation.

If you have an interesting use-case that does not follow the examples below,
please share!

## Virtual files

Let's assume that an autoindex is enabled on `/public/` and that we want to zip
directories on the fly by appending '.zip' to the directory name in the URL:
requesting `/public/banana/` would list the content of the 'banana' directory,
while requesting `/public/banana.zip` would download 'banana.zip' generated on
the fly with the content of `/public/banana/`.

To achieve this, you can use the following `location` configuration:

    location /public/ {
        location ~ \.zip$ {
            try_files $uri $uri/ @try_zip;
        }

        # some configuration
        ...
    }

This will intercept requests for a zip file under `/public/` matching on the
extension, and if no actual file has the requested name, nor directory (which
can also have their name end with '.zip'), the fallback named location
`@try_zip` will be used:

    location @try_zip {
        content_by_lua_block {
            local autozip = require 'autozip'
            autozip.try_zip('=404')
        }
    }

Much like `try_files`, you provide a fallback location to `autozip.try_zip`
(here a redirection to an HTTP 404 error page, handled by nginx' error handler).

Autozip will try to figure out whether it can serve the directory
`/public/banana/` as a zip, and if not redirect to the fallback location.

## Explicit query parameter

Let's assume that an autoindex is enabled on `/public/` and that we want to zip
directories on the fly when the query parameter `download` is present.

Matching query parameters is a bit more tricky, as nginx does not let you
directly match locations on them.

One way to handle this would be to configure a custom error handler and trigger
it when the query parameters match:

    location / {
        error_page 418 @try_zip;
        recursive_error_pages on;

        if ($args ~ (^|&)download(&|$)) {
            return 418;
        }

        # some configuration
        ...
    }

The `@try_zip` named location (see previous example) would generate the zip.
Note that with the current `autozip.lua` code this scenario would require a
slight adaptation to make it work, as the primary focus was the "Virtual files"
use-case. Future versions might improve the situation, and so can you by
contributing!




[mod_zip]: https://www.nginx.com/resources/wiki/modules/zip/
