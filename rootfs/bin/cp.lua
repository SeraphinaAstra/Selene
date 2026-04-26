local fs = require("nyx.fs")
local src, dst = ...
if not src or not dst then print("usage: cp(src, dst)"); return end
local data, err = fs.read(src)
if not data then print("cp: " .. tostring(err)); return end
local ok, err = fs.write(dst, data)
if not ok then print("cp: " .. tostring(err)); return end
print("cp: " .. src .. " -> " .. dst)