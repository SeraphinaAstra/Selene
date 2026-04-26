-- nyx/sched.lua
-- Selene scheduler — cooperative with timer-driven preemption

local sched = {}

-- Process table: { id, name, co, status }
-- status: "ready" | "running" | "dead"
local procs    = {}
local next_pid = 1
local current_pid = nil

-- ------------------------------------------------------------------ --
-- Process management                                                   --
-- ------------------------------------------------------------------ --

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

-- ------------------------------------------------------------------ --
-- Timer hook entry point                                               --
-- Called by interrupts.c lua_hook() when the CLINT fires.             --
-- Must be a global so C can reach it via lua_getglobal().             --
-- ------------------------------------------------------------------ --

function sched.tick()
    -- Only yield if we're actually inside a scheduled coroutine.
    -- If the timer fires while the kernel itself is running (no
    -- current process), there's nothing to preempt — ignore it.
    -- Also check coroutine.running() to ensure we are not in the main scheduler thread
    if current_pid ~= nil and coroutine.running() ~= nil then
        coroutine.yield()
    end
end

-- Expose as global for the C hook
_G.sched_tick = sched.tick

-- ------------------------------------------------------------------ --
-- Scheduler loop                                                       --
-- ------------------------------------------------------------------ --

function sched.run()
    timer_start()  -- arm CLINT timer now that scheduler is actually running
    while true do
        local any = false

        -- collect pids in order so iteration is deterministic
        local pids = {}
        for pid in pairs(procs) do
            pids[#pids + 1] = pid
        end
        table.sort(pids)

        for _, pid in ipairs(pids) do
            local p = procs[pid]
            if p and p.status == "ready" then
                any = true
                current_pid = pid
                p.status = "running"

                local ok, err = coroutine.resume(p.co)

                if not ok then
                    print(string.format(
                        "sched: pid %d (%s) crashed: %s",
                        pid, p.name, tostring(err)
                    ))
                    p.status = "dead"
                elseif coroutine.status(p.co) == "dead" then
                    p.status = "dead"
                else
                    -- resumed fine and yielded — back to ready
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

        if not any then
            timer_stop()  -- disarm CLINT timer before returning to shell
            break
        end
    end
end

return sched