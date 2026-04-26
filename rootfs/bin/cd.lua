local fs = require("nyx.fs")
local path = ...
if not path then
    rawset(_G, "_cwd", "/")
    return
end

local target
if path:sub(1,1) == "/" then
    target = path
elseif _cwd == "/" then
    target = "/" .. path
else
    target = _cwd .. "/" .. path
end

-- normalize . and ..
local parts = {}
for part in target:gmatch("[^/]+") do
    if part == ".." then
        table.remove(parts)
    elseif part ~= "." then
        table.insert(parts, part)
    end
end
target = "/" .. table.concat(parts, "/")

if not fs.exists(target) then
    print("cd: not found: " .. target)
    return
end

rawset(_G, "_cwd", target)