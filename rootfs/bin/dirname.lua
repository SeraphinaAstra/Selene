-- /bin/dirname.lua
local path = ...
if not path or path == "" then
    print("/")
    return
end

local dir = path:match("(.+)/[^/]*$") or "/"
print(dir)