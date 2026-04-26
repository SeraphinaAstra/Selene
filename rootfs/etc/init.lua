-- /etc/init.lua
-- Selene init — normal boot path, reached only if mount() succeeded

local function try(path)
    local fs = require("nyx.fs")
    local data, err = fs.read(path)
    if not data then
        print("init: failed to load " .. path .. ": " .. tostring(err))
        return false
    end
    local fn, err = load(data, "@" .. path)
    if not fn then
        print("init: parse error in " .. path .. ": " .. tostring(err))
        return false
    end
    local ok, err = pcall(fn)
    if not ok then
        print("init: runtime error in " .. path .. ": " .. tostring(err))
        return false
    end
    return true
end

print("init: starting Selene")

-- spawn shell for now — Phase 4 this becomes a real login process
require("nyx.shell")