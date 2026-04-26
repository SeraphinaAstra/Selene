-- nyx/core.lua
-- Selene kernel core — boot policy lives here, not in boot.c

local proc  = require("nyx.proc")
local sched = require("nyx.sched")
local fs    = require("nyx.fs")

local nyx = {}

nyx.version = "0.4-dev"
nyx.arch    = "riscv64"

nyx.spawn   = proc.spawn
nyx.kill    = proc.kill
nyx.list    = proc.list
nyx.yield   = proc.yield

function nyx.info()
    local si = sysinfo()
    print("Selene " .. nyx.version .. " on " .. nyx.arch)
    print("heap:    " .. si.heap_kb .. "KB")
    print("rdfiles: " .. si.ramdisk_files)
end

function nyx.panic(msg)
    print("KERNEL PANIC: " .. tostring(msg))
    print("system halted")
    while true do end
end

-- ── Boot policy ───────────────────────────────────────────────────────

local function recovery(reason)
    if reason then
        print("warn: " .. reason)
    end
    print("warn: dropping to recovery shell")
    print("type help() for available commands")
    require("nyx.shell")
end

local function boot()
    print("nyx: kernel core v" .. nyx.version)

    local ok, err = fs.mount()
    if not ok then
        recovery("mount failed: " .. tostring(err))
        return
    end

    -- disk is up, mark it globally so shell builtins work if we fall back
    _mounted = true

    if fs.exists("/etc/init.lua") then
        local data, err = fs.read("/etc/init.lua")
        if not data then
            recovery("/etc/init.lua unreadable: " .. tostring(err))
            return
        end
        local fn, err = load(data, "@/etc/init.lua")
        if not fn then
            recovery("/etc/init.lua parse error: " .. tostring(err))
            return
        end
        local ok, err = pcall(fn)
        if not ok then
            recovery("/etc/init.lua runtime error: " .. tostring(err))
            return
        end
    else
        recovery("/etc/init.lua not found")
    end
end

if not _nyx_loaded then
    _nyx_loaded = true
    boot()
end

return nyx
