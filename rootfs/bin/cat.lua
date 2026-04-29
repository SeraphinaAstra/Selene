-- /bin/cat.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: cat <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("cat: " .. tostring(err or "not found: " .. path))
    return
end

print(data)