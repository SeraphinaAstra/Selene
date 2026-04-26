local fs = require("nyx.fs")
local path = ...
if not path then print("usage: rm(path)"); return end
local ok, err = fs.delete(path)
if not ok then print("rm: " .. tostring(err)); return end
print("rm: deleted " .. path)