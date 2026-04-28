# Selene Complete API Reference

## Global Functions (C registered, always available)

These are available at boot time in every Lua context, no require needed.

| Function | Description |
|---|---|
| `peek32(addr)` | Read 32-bit MMIO register at physical address |
| `poke32(addr, value)` | Write 32-bit value to MMIO register at physical address |
| `sysinfo()` | Returns table: `{ arch, heap_kb, ramdisk_files }` |
| `getchar()` | Read one raw byte from UART (blocks) |
| `getchar_nb()` | Non-blocking character read. Returns character integer if available, `nil` immediately if no input |
| `kbhit()` | Check if input is available. Returns boolean, never blocks |
| `readline()` | Read line from UART with echo and backspace support |
| `prompt()` | Print `> ` shell prompt |
| `putstr(s)` | Write raw string to UART, no newline |
| `readkey()` | Read one keypress, handles ANSI escapes, returns char or named key: `UP`, `DOWN`, `LEFT`, `RIGHT`, `HOME`, `END`, `DEL`, `ESC` |
| `rd_find(path)` | Find file in ramdisk, returns content string or nil |
| `rd_list()` | List all ramdisk file paths as table |
| `yield()` | Yield execution to scheduler |
| `virtio_init()` | Initialize VirtIO block device, returns true or nil, err |
| `virtio_read_sector(n)` | Read 512-byte sector from disk, returns string or nil, err |
| `virtio_write_sector(n, data)` | Write 512-byte sector to disk, returns true or nil, err |
| `gpu_init()` | Initialize VirtIO GPU, returns true or nil, err |
| `fb_ptr()` | Return framebuffer base address as integer |
| `fb_size()` | Returns `width, height` |
| `fb_poke(x, y, rgba)` | Write one 32-bit RGBA pixel to framebuffer |
| `fb_fill(rgba)` | Fill entire framebuffer with solid color |
| `fb_flush([x, y, w, h])` | Flush region to display. No parameters flushes full screen |
| `gpu_debug()` | Returns diagnostic table for GPU state |
| `timer_start()` | Start preemptive scheduler timer interrupts |
| `timer_stop()` | Stop scheduler timer interrupts |

---

## Nyx Kernel Modules

### `nyx/core.lua`
```lua
local nyx = require("nyx.core")
```

| Field / Function | Description |
|---|---|
| `nyx.version` | Kernel version string |
| `nyx.arch` | Architecture string |
| `nyx.spawn(name, fn)` | Spawn new process |
| `nyx.kill(pid)` | Terminate process by pid |
| `nyx.list()` | Print running process table |
| `nyx.yield()` | Yield execution |
| `nyx.info()` | Print system info to console |
| `nyx.panic(msg)` | Kernel panic, halt system |

---

### `nyx/fs.lua`
```lua
local fs = require("nyx.fs")
```

| Function | Description |
|---|---|
| `fs.mount()` | Mount ext2 filesystem on VirtIO block. Returns true or nil, err |
| `fs.list([path])` | List directory entries. Path defaults to "/" |
| `fs.read(path)` | Read entire file content as string. Returns content or nil, err |
| `fs.write(path, data)` | Create or overwrite file. Returns true or nil, err |
| `fs.exists(path)` | Returns boolean indicating if path exists |
| `fs.delete(path)` | Delete file (only marks directory entry as deleted) |
| `fs.mkdir(path)` | Create new directory. Returns true or nil, err |
| `fs.info()` | Returns filesystem statistics table: `{ block_count, block_size, free_blocks, inode_count, free_inodes, ... }` |

---

### `nyx/proc.lua`
```lua
local proc = require("nyx.proc")
```

| Function | Description |
|---|---|
| `proc.spawn(name, fn)` | Spawn new coroutine-based process. Returns pid |
| `proc.kill(pid)` | Kill process by pid |
| `proc.list()` | Print formatted process list to console |
| `proc.current()` | Returns current running pid |
| `proc.yield()` | Yield execution to scheduler |
| `proc.run()` | Start scheduler main loop |

---

### `nyx/sched.lua`
```lua
local sched = require("nyx.sched")
```

| Function | Description |
|---|---|
| `sched.spawn(name, fn)` | Low level spawn. Returns pid |
| `sched.kill(pid)` | Low level kill |
| `sched.current()` | Returns current pid |
| `sched.list()` | Print raw process list |
| `sched.yield()` | Direct coroutine yield |
| `sched.run()` | Start preemptive scheduler loop |

---

### `nyx/shell.lua`
```lua
require("nyx.shell")
```

Loading this module drops directly into the interactive REPL loop. The following builtin functions become available globally:

| Builtin | Description |
|---|---|
| `sys()` | System information |
| `mem()` | Heap usage |
| `ver()` | Version string |
| `ps()` | Process list |
| `mount()` | Mount filesystem |
| `rdls()` | List ramdisk contents |
| `rdread(path)` | Read from ramdisk |
| `run(path, ...)` | Run lua file from disk or ramdisk |
| `cd(path)` | Change working directory |
| `echo(...)` | Print arguments |
| `fwrite(path, data)` | Raw file write |
| `finfo()` | Filesystem info |
| `edit(path)` | Open full screen text editor |
| `help()` | Print help text |

Post-mount `/bin/` commands also become available:
`ls()`, `cat()`, `cp()`, `mv()`, `rm()`, `mkdir()`, `pwd()`, `df()`, `uname()`, `clear()`, `hexdump()`, `wc()`, `grep()`

---

### `nyx/drivers/fb.lua`
```lua
local fb = require("nyx.drivers.fb")
```

| Function | Description |
|---|---|
| `fb.init([opts])` | Initialize framebuffer terminal. Opts: `{ install_print = true }` to override global print |
| `fb.print(...)` | Print to framebuffer terminal |
| `fb.write(str)` | Write string without newline |
| `fb.putc(c)` | Write single character |
| `fb.clear()` | Clear screen and reset cursor |
| `fb.redraw()` | Redraw entire terminal buffer |
| `fb.set_colors(fg, bg)` | Set foreground/background RGBA colors |
| `fb.cursor()` | Returns `cx, cy` |
| `fb.set_cursor(x, y)` | Move cursor position |
| `fb.backspace()` | Delete last character |
| `fb.install()` | Replace global `print()` with framebuffer print |
| `fb.uninstall()` | Restore original print function |
| `fb.raw_print(...)` | Always write to UART, even if framebuffer is active |

---

### `nyx/drivers/uart.lua`
```lua
local uart = require("nyx.drivers.uart")
```

| Function | Description |
|---|---|
| `uart.putc(c)` | Write character |
| `uart.getc()` | Read character |
| `uart.puts(s)` | Write string |

---

### `nyx/drivers/virtio.lua`
```lua
local virtio = require("nyx.drivers.virtio")
```

| Function | Description |
|---|---|
| `virtio.init()` | Initialize block device |
| `virtio.read(n)` | Read sector |
| `virtio.write(n, data)` | Write sector |

---

## Filesystem Limitations
- Maximum file size: 12KB (only direct block pointers implemented)
- No indirect block support
- No file permissions enforcement
- Deleting files does not free blocks or inodes
- All allocations go to block group 0 only

## Scheduler Notes
- Round-robin coroutine based scheduler
- Preemptive scheduling via 100Hz CLINT timer interrupt
- No memory isolation between processes
- Full kernel VM shared between all processes