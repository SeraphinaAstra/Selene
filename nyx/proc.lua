-- nyx/proc.lua
-- Selene process management — wraps sched with a clean API

local sched = require("nyx.sched")

local proc = {}

function proc.spawn(name, fn)
    local pid = sched.spawn(name, fn)
    print("proc: spawned [" .. pid .. "] " .. name)
    return pid
end

function proc.kill(pid)
    sched.kill(pid)
    print("proc: killed [" .. pid .. "]")
end

function proc.list()
    print("PID  NAME             STATUS")
    print("---  ----             ------")
    sched.list()
end

function proc.current()
    return sched.current()
end

function proc.yield()
    sched.yield()
end

function proc.run()
    sched.run()
end

return proc