local fs = require("nyx.fs")
local path = ...
if not path then print("usage: mkdir(path)"); return end
local ok, err = fs.mkdir(path)
if not ok then print("mkdir: " .. tostring(err)); return end
print("mkdir: created " .. path)