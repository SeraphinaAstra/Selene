-- /bin/hexdump.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: hexdump <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("hexdump: " .. tostring(err or "not found: " .. path))
    return
end

local offset = 0
while offset < #data do
    local chunk = data:sub(offset + 1, offset + 16)
    local hex = {}
    local asc = {}

    for i = 1, #chunk do
        local b = chunk:byte(i)
        table.insert(hex, string.format("%02x", b))
        table.insert(asc, (b >= 32 and b < 127) and string.char(b) or ".")
    end

    -- Pad last line
    for i = #chunk + 1, 16 do
        table.insert(hex, "  ")
        table.insert(asc, " ")
    end

    print(string.format("%08x  %-23s %-23s |%s|",
        offset,
        table.concat(hex, " ", 1, 8),
        table.concat(hex, " ", 9, 16),
        table.concat(asc)))

    offset = offset + 16
end

print(string.format("%08x", #data))