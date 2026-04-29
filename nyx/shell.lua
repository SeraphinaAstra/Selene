-- nyx/shell.lua
-- Selene shell - Hybrid Lua REPL + Shell

local _fs = nil
local function getfs()
    if not _fs then _fs = require("nyx.fs") end
    return _fs
end

local fb = nil
local function getfb()
    if not fb then
        fb = require("nyx.drivers.fb")
        if fb.init then pcall(fb.init) end
    end
    return fb
end

if _mounted == nil then _mounted = true end   -- we know it's mounted at boot
if _cwd == nil then _cwd = "/" end

local old_print = print

local function uart_write(s)
    s = tostring(s or "")
    if type(putstr) == "function" then
        putstr(s:gsub("\n", "\r\n"))
    else
        old_print(s)
    end
end

local function fb_write(s)
    local m = getfb()
    if m and m.write then m.write(s) end
end

local function console_write(s)
    uart_write(s)
    fb_write(s)
end

local function console_print(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    console_write(table.concat(t, " ") .. "\n")
end

_G.print = console_print

-- Improved path normalization
local function normalize_path(path)
    if not path or path == "" then return _cwd end

    -- Make absolute if needed
    if path:sub(1,1) ~= "/" then
        path = _cwd .. ( _cwd == "/" and "" or "/" ) .. path
    end

    local parts = {}
    for p in path:gmatch("[^/]+") do
        if p == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif p ~= "." then
            table.insert(parts, p)
        end
    end

    local result = "/" .. table.concat(parts, "/")
    if result == "" then result = "/" end
    return result
end

-- Line editor
local function fb_backspace()
    local m = getfb()
    if m and m.backspace then m.backspace() end
end

local function fb_putc(ch)
    local m = getfb()
    if m then
        if m.putc then m.putc(ch) elseif m.write then m.write(ch) end
    end
end

local function tty_readline()
    local line = ""
    console_write("> ")
    while true do
        local c = getchar()
        if not c then return nil end

        if c == 13 or c == 10 then
            console_write("\n")
            return line
        elseif (c == 8 or c == 127) and #line > 0 then
            line = line:sub(1, -2)
            uart_write("\b \b")
            fb_backspace()
        elseif c == 9 then
            for _ = 1, 4 do
                line = line .. " "
                uart_write(" ")
                fb_putc(" ")
            end
        elseif c >= 32 and c < 127 then
            local ch = string.char(c)
            line = line .. ch
            uart_write(ch)
            fb_putc(ch)
        end
    end
end

-- ====================== Built-ins ======================

function mount()
    if _mounted then return print("already mounted") end
    local ok, err = getfs().mount()
    if ok then
        _mounted = true
        print("mounted")
    else
        print("mount failed: " .. tostring(err))
    end
end

function cd(path)
    if not path then
        _cwd = "/"
        return
    end
    local target = normalize_path(path)
    if getfs().exists(target) then
        _cwd = target
    else
        print("cd: no such directory: " .. target)
    end
end

function echo(...) 
    print(table.concat({...}, " ")) 
end

function help()
    print("\nSelene shell")
    print("You can type Lua code or shell commands without parentheses.\n")
    print("Built-in commands:")
    print("  help  mount  cd [path]  echo ...  sys  mem  ver  ps  rdls  rdread  finfo")
    print("\nCommands from /bin/:")
    print("  ls  cat  cp  mv  rm  mkdir  pwd  df  clear  edit  run")
    print("  hexdump  wc  grep  snake  uname find env grep pwd tree touch whoami \n")
    print("  tail head diff dirname basename stat ... \n")
    print("Tip: You can also run Lua scripts directly with run <path> and pass arguments.")
    print("Tip: Most commands work like traditional shell (no () needed).")
end

function sys()
    local i = sysinfo()
    print("arch: " .. i.arch)
    print("heap: " .. i.heap_kb .. "KB")
    print("ramdisk: " .. i.ramdisk_files)
    print("disk: mounted")
end

function mem() print("heap: " .. sysinfo().heap_kb .. "KB") end
function ver() print("Selene " .. (nyx and nyx.version or "0.4-dev") .. " riscv64") end
function ps() require("nyx.proc").list() end
function rdls() for _,f in ipairs(rd_list()) do print(f) end end

function rdread(path)
    if not path then return print("usage: rdread <path>") end
    local data = rd_find(path)
    print(data or "not found: " .. path)
end

function finfo()
    local info = getfs().info()
    if not info then return print("not mounted") end
    print(string.format("blocks: %d  free: %d  block_size: %d", 
        info.block_count or 0, info.free_blocks or 0, info.block_size))
end

-- ====================== run() - Critical Fix ======================

function run(path, ...)
    if not path then return print("usage: run <path>") end

    path = normalize_path(path)
    local data = _mounted and getfs().read(path) or nil
    if not data then
        data = rd_find(path)
    end

    if not data then
        print("run: not found: " .. path)
        return
    end

    local fn, err = load(data, "@" .. path)
    if not fn then
        print("run: syntax error in " .. path)
        print(err)
        return
    end

    -- Wrap so that ... works correctly inside the script
    local ok, res = pcall(function(...) return fn(...) end, ...)
    if not ok then
        print("error in " .. path .. ": " .. tostring(res))
    elseif res ~= nil then
        print(res)
    end
end

-- ====================== Main Executor ======================

local function execute_line(line)
    if #line == 0 then return end

    -- Try as Lua first
    local fn, err = load(line, "=stdin")
    if fn then
        local ok, res = pcall(fn)
        if not ok then
            print("Error: " .. tostring(res))
        elseif res ~= nil then
            print(res)
        end
        return
    end

    -- Shell command
    local parts = {}
    for w in line:gmatch("%S+") do table.insert(parts, w) end

    local cmd = parts[1]
    local args = { table.unpack(parts, 2) }

    -- Built-in command?
    if type(_G[cmd]) == "function" then
        local ok, res = pcall(_G[cmd], table.unpack(args))
        if not ok then
            print(cmd .. ": " .. tostring(res))
        end
        return
    end

    -- Try /bin/<cmd>.lua
    if _mounted then
        local ok = pcall(run, "/bin/" .. cmd .. ".lua", table.unpack(args))
        if ok then return end
    end

    print("unknown command: " .. cmd)
end

function shell_start()
    local m = getfb()
    if m and m.clear then pcall(m.clear) end

    print("Selene shell -- Lua is the shell")
    print("Type help for commands\n")

    while true do
        local line = tty_readline()
        if not line then break end
        execute_line(line)
    end
end