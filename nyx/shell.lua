-- nyx/shell.lua
-- Selene interactive REPL + builtins

function ls()
    local files = rd_list()
    for _, path in ipairs(files) do
        print(path)
    end
end

function read(path)
    local data = rd_find(path)
    if data then
        print(data)
    else
        print("read: not found: " .. tostring(path))
    end
end

function run(path)
    local data = rd_find(path)
    if not data then
        print("run: not found: " .. tostring(path))
        return
    end
    local fn, err = load(data, "@" .. path)
    if not fn then
        print("run: " .. tostring(err))
        return
    end
    local ok, res = pcall(fn)
    if not ok then print("run error: " .. tostring(res)) end
end

function mem()
    local info = sysinfo()
    print("heap: " .. info.heap_kb .. "KB")
end

function sys()
    local info = sysinfo()
    print("arch:    " .. info.arch)
    print("heap:    " .. info.heap_kb .. "KB")
    print("rdfiles: " .. info.ramdisk_files)
end

function ver()
    local nyx = require("nyx.core")
    nyx.info()
end

function ps()
    local proc = require("nyx.proc")
    proc.list()
end

function help()
    print("Selene (SNK) -- Lua is the shell")
    print("")
    print("builtins:")
    print("  ls()             list ramdisk files")
    print("  read(path)       dump file contents")
    print("  run(path)        execute a ramdisk file")
    print("  mem()            memory info")
    print("  sys()            system info")
    print("  ps()             process list")
    print("  ver()            version info")
    print("  help()           this")
    print("")
    print("everything else is valid Lua")
end

-- REPL
while true do
    prompt()
    local line = readline()
    if not line then break end
    if #line > 0 then
        local fn, err = load(line)
        if fn then
            local ok, res = pcall(fn)
            if not ok then
                print("Error: " .. tostring(res))
            elseif res ~= nil then
                print(res)
            end
        else
            print("Error: " .. tostring(err))
        end
    end
end