-- /bin/grep.lua
local fs = require("nyx.fs")

local pattern, path = ...
if not pattern or not path then
    print("usage: grep <pattern> <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("grep: " .. tostring(err or "cannot read " .. path))
    return
end

local count = 0
local lnum = 0

for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    lnum = lnum + 1
    if line:find(pattern) then
        print(string.format("%4d: %s", lnum, line))
        count = count + 1
    end
end

if count == 0 then
    print("grep: no matches")
end