local fs = require("nyx.fs")
local path = ... or _cwd or "/"
local t, err = fs.list(path)
if not t then print("ls: " .. tostring(err)); return end
table.sort(t)
for _, n in ipairs(t) do
    if n ~= "." and n ~= ".." then
        print(n)
    end
end