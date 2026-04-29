-- /bin/stat.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: stat <file>")
    return
end

if not fs.exists(path) then
    print("stat: cannot stat '" .. path .. "': No such file or directory")
    return
end

local is_dir = fs.list(path) ~= nil

print("  File: " .. path)
print("  Type: " .. (is_dir and "directory" or "regular file"))
print("  Size: " .. (#(fs.read(path) or "") .. " bytes"))