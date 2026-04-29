-- /bin/diff.lua
local fs = require("nyx.fs")

local file1, file2 = ...
if not file1 or not file2 then
    print("usage: diff <file1> <file2>")
    return
end

local data1 = fs.read(file1)
local data2 = fs.read(file2)

if not data1 then
    print("diff: cannot read " .. file1)
    return
end
if not data2 then
    print("diff: cannot read " .. file2)
    return
end

local lines1, lines2 = {}, {}
for line in (data1.."\n"):gmatch("([^\n]*)\n") do table.insert(lines1, line) end
for line in (data2.."\n"):gmatch("([^\n]*)\n") do table.insert(lines2, line) end

local max_lines = math.max(#lines1, #lines2)

for i = 1, max_lines do
    local l1 = lines1[i] or ""
    local l2 = lines2[i] or ""

    if l1 ~= l2 then
        if l1 ~= "" then print("< " .. l1) end
        if l2 ~= "" then print("> " .. l2) end
    end
end