-- /bin/wc.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: wc <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("wc: " .. tostring(err or "not found: " .. path))
    return
end

local lines, words, bytes = 0, 0, #data

for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    lines = lines + 1
    for _ in line:gmatch("%S+") do
        words = words + 1
    end
end

print(string.format("%8d %8d %8d %s", lines, words, bytes, path))