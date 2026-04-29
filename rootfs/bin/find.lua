-- /bin/find.lua
local fs = require("nyx.fs")

local function find(path, pattern)
    local items = fs.list(path)
    if not items then return end

    for _, name in ipairs(items) do
        if name ~= "." and name ~= ".." then
            local full = (path == "/" and "/" or path .. "/") .. name

            if name:find(pattern) then
                print(full)
            end

            -- Recurse into directories
            if fs.list(full) then   -- crude directory check
                find(full, pattern)
            end
        end
    end
end

local pattern = ...
if not pattern then
    print("usage: find <pattern>")
    return
end

find(_cwd or "/", pattern)