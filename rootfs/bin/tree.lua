-- /bin/tree.lua
local fs = require("nyx.fs")

local function print_tree(path, prefix)
    local items, err = fs.list(path)
    if not items then return end

    table.sort(items)

    for i, name in ipairs(items) do
        if name ~= "." and name ~= ".." then
            local is_last = (i == #items)
            local connector = is_last and "└── " or "├── "
            local new_prefix = is_last and "    " or "│   "

            print(prefix .. connector .. name)

            local fullpath = path == "/" and "/" .. name or path .. "/" .. name
            if fs.exists(fullpath) and fs.list(fullpath) then
                print_tree(fullpath, prefix .. new_prefix)
            end
        end
    end
end

local path = ... or _cwd or "/"
print(path)
print_tree(path, "")