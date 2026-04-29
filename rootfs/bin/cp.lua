-- /bin/cp.lua
local fs = require("nyx.fs")

local src, dst = ...
if not src or not dst then
    print("usage: cp <source> <destination>")
    return
end

local data, err = fs.read(src)
if not data then
    print("cp: " .. tostring(err or "cannot read " .. src))
    return
end

local ok, err = fs.write(dst, data)
if not ok then
    print("cp: " .. tostring(err or "cannot write to " .. dst))
    return
end

print(src .. " -> " .. dst)