-- /bin/mv.lua
local fs = require("nyx.fs")

local src, dst = ...
if not src or not dst then
    print("usage: mv <source> <destination>")
    return
end

local data, err = fs.read(src)
if not data then
    print("mv: cannot read " .. src .. ": " .. tostring(err))
    return
end

local ok, err = fs.write(dst, data)
if not ok then
    print("mv: cannot write to " .. dst .. ": " .. tostring(err))
    return
end

local ok, err = fs.delete(src)
if not ok then
    print("mv: warning - failed to delete source: " .. tostring(err))
end

print(src .. " -> " .. dst)