-- nyx/sched.lua
-- Selene cooperative coroutine scheduler

local sched = {}

-- Process table: { id, name, co, status }
-- status: "ready" | "running" | "dead"
local procs = {}
local next_pid = 1
local current_pid = nil

function sched.spawn(name, fn)
    local pid = next_pid
    next_pid = next_pid + 1
    procs[pid] = {
        id     = pid,
        name   = name,
        co     = coroutine.create(fn),
        status = "ready",
    }
    return pid
end

function sched.kill(pid)
    if procs[pid] then
        procs[pid].status = "dead"
    end
end

function sched.current()
    return current_pid
end

function sched.list()
    for pid, p in pairs(procs) do
        print(string.format("  [%d] %-16s %s", pid, p.name, p.status))
    end
end

function sched.yield()
    coroutine.yield()
end

function sched.run()
    while true do
        local any = false

        for pid, p in pairs(procs) do
            if p.status == "ready" then
                any = true
                current_pid = pid
                p.status = "running"

                local ok, err = coroutine.resume(p.co)

                if not ok then
                    print("sched: process " .. pid .. " (" .. p.name .. ") crashed: " .. tostring(err))
                    p.status = "dead"
                elseif coroutine.status(p.co) == "dead" then
                    p.status = "dead"
                else
                    p.status = "ready"
                end

                current_pid = nil
            end
        end

        -- Reap dead processes
        for pid, p in pairs(procs) do
            if p.status == "dead" then
                procs[pid] = nil
            end
        end

        if not any then break end
    end
end

return sched