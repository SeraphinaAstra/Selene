-- nyx/shell.lua
-- Selene recovery shell + interactive REPL

local _fs = nil
local function getfs()
    if not _fs then _fs = require("nyx.fs") end
    return _fs
end

if _mounted == nil then _mounted = false end
if _cwd == nil then _cwd = "/" end

local function resolve_path(path)
    if path:sub(1,1) == "/" then return path end
    if _cwd == "/" then return "/" .. path end
    return _cwd .. "/" .. path
end

-- ── Builtins ─────────────────────────────────────────────────────────

function mount()
    if _mounted then print("already mounted"); return end
    local ok, err = getfs().mount()
    if ok then
        _mounted = true
        print("mounted")
    else
        print("mount failed: " .. tostring(err))
    end
end

function rdls()
    local files = rd_list()
    for _, path in ipairs(files) do print(path) end
end

function rdread(path)
    local data = rd_find(path)
    if data then print(data)
    else print("rdread: not found: " .. tostring(path)) end
end

function run(path, ...)
    -- disk first, ramdisk as fallback
    local data
    path = resolve_path(path)
    if _mounted then
        local f = getfs().read(path)
        if f then data = f end
    end
    if not data then
        data = rd_find(path)
    end
    if not data then
        print("run: not found: " .. tostring(path)); return
    end
    local fn, err = load(data, "@" .. path)
    if not fn then print("run: " .. tostring(err)); return end
    local ok, res = pcall(fn, ...)
    if not ok then print("run error: " .. tostring(res)) end
end

function fwrite(path, data)
    if not path or not data then print("usage: fwrite(path, data)"); return end
    local ok, err = getfs().write(path, data)
    if not ok then print("fwrite: " .. tostring(err))
    else print("wrote " .. #data .. " bytes to " .. path) end
end

function finfo()
    local info = getfs().info()
    if not info then print("not mounted"); return end
    print(string.format("blocks: %d  inodes: %d  block_size: %d  groups: %d",
        info.blocks, info.inodes, info.block_size, info.groups))
end

function edit(path)
    if not path then print("usage: edit(path)"); return end
    if not _mounted then print("edit: disk not mounted"); return end
    run("/bin/edit.lua", path)
end

function cd(path)
    if not path then rawset(_G, "_cwd", "/"); return end
    local target
    if path:sub(1,1) == "/" then
        target = path
    elseif _cwd == "/" then
        target = "/" .. path
    else
        target = _cwd .. "/" .. path
    end
    local parts = {}
    for part in target:gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then table.insert(parts, part) end
    end
    target = "/" .. table.concat(parts, "/")
    local fs = getfs()
    if not fs.exists(target) then print("cd: not found: " .. target); return end
    rawset(_G, "_cwd", target)
end

function echo(...)
    local args = {...}
    if #args == 0 then print(""); return end
    local parts = {}
    for _, v in ipairs(args) do table.insert(parts, tostring(v)) end
    print(table.concat(parts, " "))
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
    print("Selene " .. (nyx and nyx.version or "0.4-dev") .. " on riscv64")
end

function help()
    print("Selene recovery shell -- Lua is the shell")
    print("")
    print("always available:")
    print("  sys()                 system info")
    print("  mem()                 memory info")
    print("  ver()                 version info")
    print("  ps()                  process list")
    print("  mount()               mount ext2 filesystem")
    print("  rdls()                list ramdisk files")
    print("  rdread(path)          read ramdisk file")
    print("  run(path)             run file (disk first, ramdisk fallback)")
    print("  cd(path)              change directory")
    print("  echo(...)             print arguments")
    print("  help()                this")
    print("")
    print("after mount():")
    print("  ls(path)              list disk directory")
    print("  cat(path)             read disk file")
    print("  fwrite(path, data)    write disk file")
    print("  finfo()               filesystem info")
    print("  edit(path)            screen editor")
    print("  /bin/<cmd>.lua        disk commands")
    print("")
    print("disk commands (after mount):")
    print("  cp(src, dst)          copy file")
    print("  mv(src, dst)          move/rename file")
    print("  rm(path)              delete file")
    print("  mkdir(path)           create directory")
    print("  pwd                   print working directory")
    print("  df                    disk usage")
    print("  uname                 system info")
    print("  clear                 clear screen")
    print("  hexdump(path)         hex dump file")
    print("  wc(path)              word/line/byte count")
    print("  grep(pattern, path)   search file")
    print("")
    print("everything else is valid Lua")
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