-- nyx/shell.lua
-- Selene interactive REPL + builtins

local _fs = nil
local function getfs()
    if not _fs then _fs = require("nyx.fs") end
    return _fs
end

_mounted = false

-- ── Builtins ─────────────────────────────────────────────────────────

function mount()
    local ok, err = getfs().mount()
    if ok then _mounted = true
    else print("mount failed: " .. tostring(err)) end
end

function ls()
    local files = rd_list()
    for _, path in ipairs(files) do print(path) end
end

function read(path)
    local data = rd_find(path)
    if data then print(data)
    else print("read: not found: " .. tostring(path)) end
end

function run(path, ...)
    local data = rd_find(path)
    if not data and _mounted then
        local f, err = getfs().read(path)
        if not f then print("run: not found: " .. tostring(path)); return end
        data = f
    elseif not data then
        print("run: not found: " .. tostring(path)); return
    end
    local fn, err = load(data, "@" .. path)
    if not fn then print("run: " .. tostring(err)); return end
    local ok, res = pcall(fn, ...)
    if not ok then print("run error: " .. tostring(res)) end
end

function fls(path)
    local t, err = getfs().list(path or "/")
    if not t then print("fls: " .. tostring(err)); return end
    for _, n in ipairs(t) do print(n) end
end

function fread(path)
    local d, err = getfs().read(path)
    if not d then print("fread: " .. tostring(err)); return end
    print(d)
end

function fwrite(path, data)
    if not path or not data then print("usage: fwrite(path, data)"); return end
    local ok, err = getfs().write(path, data)
    if not ok then print("fwrite: " .. tostring(err))
    else print("wrote " .. #data .. " bytes to " .. path) end
end

function finfo()
    getfs().info()
end

function edit(path)
    if not path then print("usage: edit(path)"); return end
    if not _mounted then print("edit: disk not mounted"); return end
    run("/bin/edit.lua", path)
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
    print("disk:    " .. (_mounted and "mounted" or "not mounted"))
end

function ps()
    local proc = require("nyx.proc")
    proc.list()
end

function ver()
    local nyx = require("nyx.core")
    nyx.info()
end

function help()
    print("Selene (SNK) -- Lua is the shell")
    print("")
    print("ramdisk:")
    print("  ls()                  list ramdisk files")
    print("  read(path)            dump ramdisk file")
    print("  run(path)             run ramdisk or disk file")
    print("disk:")
    print("  mount()               mount ext2 filesystem")
    print("  fls(path)             list directory")
    print("  fread(path)           read file")
    print("  fwrite(path, data)    write file")
    print("  finfo()               filesystem info")
    print("  edit(path)            screen editor")
    print("system:")
    print("  ps()                  process list")
    print("  mem()                 memory info")
    print("  sys()                 system info")
    print("  ver()                 version info")
    print("  help()                this")
    print("")
    print("everything else is valid Lua")
    print("/bin/<cmd>.lua runs if mounted and command unknown")
end

-- ── REPL ─────────────────────────────────────────────────────────────

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
            local word = line:match("^%s*(%w+)")
            if word and _mounted then
                local ok, runerr = pcall(run, "/bin/" .. word .. ".lua")
                if not ok then print("unknown: " .. word) end
            else
                print("Error: " .. tostring(err))
            end
        end
    end
end