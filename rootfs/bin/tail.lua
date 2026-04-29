-- /bin/tail.lua
local fs = require("nyx.fs")

local path = ...
local n = 10

if not path then
    print("usage: tail <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("tail: " .. tostring(err or "not found"))
    return
end

local lines = {}
for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
end

local start = math.max(1, #lines - n + 1)
for i = start, #lines do
    print(lines[i])
end