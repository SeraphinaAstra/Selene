-- nyx/core.lua
-- Selene kernel core — wires fs, proc, sched into a single kernel API
-- Compiled from core.tl on the dev machine, loaded at boot by boot.c

local proc  = require("nyx.proc")
local sched = require("nyx.sched")

local nyx = {}

-- Kernel version
nyx.version = "0.3-dev"
nyx.arch    = "riscv64"

-- Process API (passthrough for now, will gain permissions in Phase 3)
nyx.spawn   = proc.spawn
nyx.kill    = proc.kill
nyx.list    = proc.list
nyx.yield   = proc.yield

-- Kernel info
function nyx.info()
    local si = sysinfo()
    print("Selene " .. nyx.version .. " on " .. nyx.arch)
    print("heap:    " .. si.heap_kb .. "KB")
    print("rdfiles: " .. si.ramdisk_files)
end

-- Panic — kernel-level fatal error
function nyx.panic(msg)
    print("KERNEL PANIC: " .. tostring(msg))
    print("system halted")
    while true do end  -- halt
end

-- Boot sequence — called by boot.c after shell exits (future use)
function nyx.boot()
    print("nyx: kernel core v" .. nyx.version .. " loaded")

    -- Spawn the shell as a managed process
    proc.spawn("shell", function()
        -- shell is already running as the main loop for now
        -- this becomes meaningful in Phase 3 when shell is a real U-mode process
    end)
end

return nyx