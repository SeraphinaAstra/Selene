-- /bin/head.lua
local fs = require("nyx.fs")

local path = ...
local n = 10

if not path then
    print("usage: head [-n NUM] <file>")
    return
end

-- Very basic for now, ignore -n flag for first version
local data, err = fs.read(path)
if not data then
    print("head: " .. tostring(err or "not found"))
    return
end

local count = 0
for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    print(line)
    count = count + 1
    if count >= n then break end
end