-- /bin/basename.lua
local path = ...
if not path then
    print("usage: basename <path>")
    return
end

local name = path:match("([^/]+)$") or path
print(name)