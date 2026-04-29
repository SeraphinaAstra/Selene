-- /bin/less.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: less <file>")
    return
end

local data, err = fs.read(path)
if not data then
    print("less: " .. tostring(err or "not found: " .. path))
    return
end

local lines = {}
for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
end

local scroll = 0
local H = 22  -- visible lines

while true do
    putstr("\27[2J\27[H")  -- clear screen

    for i = 1, H do
        local idx = scroll + i
        if idx < 1 or idx > #lines then break end
        print(lines[idx])
    end

    local status = string.format("--- %s  (%d/%d) ---  q=quit  space=next  b=back", 
                                 path, scroll + H, #lines)
    putstr("\27[7m" .. status .. "\27[0m")

    local max_scroll = math.max(0, #lines - H)
    
    local key = readkey()
    if key == "q" or key == "Q" then
        break
    elseif key == " " then          -- space = page down
        scroll = math.min(scroll + H, max_scroll)
    elseif key == "b" or key == "B" then
        scroll = math.max(0, scroll - H)
    elseif key == "DOWN" then
        scroll = math.min(scroll + 1, max_scroll)
    elseif key == "UP" then
        scroll = math.max(0, scroll - 1)
    end
end

putstr("\27[2J\27[H")