local fs = require("nyx.fs")
local src, dst = ...
if not src or not dst then print("usage: mv(src, dst)"); return end
local data, err = fs.read(src)
if not data then print("mv: " .. tostring(err)); return end
local ok, err = fs.write(dst, data)
if not ok then print("mv: " .. tostring(err)); return end
local ok, err = fs.delete(src)
if not ok then print("mv: delete failed: " .. tostring(err)); return end
print("mv: " .. src .. " -> " .. dst)