local fs = require("nyx.fs")
local path = ...
if not path then print("usage: cat(path)"); return end
local d, err = fs.read(path)
if not d then print("cat: " .. tostring(err)); return end
print(d)