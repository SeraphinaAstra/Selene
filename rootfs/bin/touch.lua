-- /bin/touch.lua
local fs = require("nyx.fs")

local path = ...
if not path then
    print("usage: touch <file>")
    return
end

if fs.exists(path) then
    -- Update timestamp would be nice, but since we don't have real timestamps yet:
    print("touch: " .. path)
else
    local ok, err = fs.write(path, "")
    if ok then
        print("touch: created " .. path)
    else
        print("touch: " .. tostring(err))
    end
end