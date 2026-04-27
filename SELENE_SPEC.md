# Selene Specification
**Version:** 0.5-draft  
**Target:** RISC-V 64-bit (rv64gc), QEMU virt machine (bare metal)  
**Kernel:** Nyx  
**Classification:** Script-Native Kernel (SNK)

---

## 1. Vision

Selene is a **language-centric bare-metal operating system** where the Lua VM is the universal runtime. The distinction between *OS* and *programming environment* is intentionally minimized — the language is the OS.

> "A tiny JVM-like platform, but for Lua, running directly on bare metal in under 1MB."

Unlike JavaOS (JVM, ~100MB, slow boot) or Singularity (CLR, managed overhead, GC in ring 0), Selene achieves the same "managed runtime as kernel" concept with a ~300KB interpreter, instant boot, and manual GC control.

Selene is a **Script-Native Kernel (SNK)** — a class of OS where a high-level managed runtime is not layered on top of a traditional kernel — it *is* the kernel. The C layer exists purely as a hardware shim.

| System | Runtime | Size | Boot | GC model |
|--------|---------|------|------|----------|
| JavaOS | JVM | ~100MB | slow | stop-the-world |
| Singularity | CLR | large | moderate | managed |
| **Selene (SNK)** | **Lua 5.5** | **~1MB** | **instant** | **incremental, manual control** |

The SNK model makes one deliberate trade: raw systems performance for extreme expressiveness and safety at the kernel level. Hot paths always have the C FFI escape hatch.

### Design Principles
- **Minimal core, maximal leverage** — reuse the Lua ecosystem instead of rebuilding it
- **Language-first, OS-second** — the runtime IS the value proposition
- **Pragmatism over purity** — POSIX-ish is fine, strict compliance is not the goal
- **Fast iteration over premature complexity** — get to a working system, then build up
- **Separation of concerns via privilege modes, not language boundaries**
- **Lua is the brain, C is the muscle**

---

## 2. Architecture

### Execution Model
```
+------------------------------------------+
|   Userspace processes (U-mode)           |  <- One Lua VM per process
|   Lua / Teal / Fennel / Haxe / etc.      |
+------------------------------------------+
|   nyx/core.lua (S-mode)                  |  <- Kernel logic (Nyx)
|   One trusted kernel Lua VM              |
+------------------------------------------+
|   Lua 5.5 VM  (liblua.a)                 |  <- Pure ANSI C, ~300KB
+------------------------------------------+
|   picolibc (system toolchain)            |  <- Linked at build time, not vendored
|   boot.c | stubs.c                       |  <- C bootstrap + picolibc I/O hooks
+------------------------------------------+
|   entry.S (~20 lines RISC-V asm)         |  <- Stack setup, BSS clear, -> boot()
+------------------------------------------+
|   OpenSBI (M-mode, provided by QEMU)     |
+------------------------------------------+
```

### Privilege Model
- **M-mode:** OpenSBI — handles machine-level firmware, we never touch this
- **S-mode:** Nyx kernel — one trusted Lua VM, all kernel logic lives here
- **U-mode:** User processes — one independent Lua VM per process (Phase 4)

### Why one VM per process
- Strong crash isolation — a user process dying does not touch the kernel VM
- ~300KB-1MB overhead per VM is acceptable on any remotely modern target
- Matches what developers expect from a process model
- Clean security boundary between kernel and user code

---

## 3. C Bootstrap Layer

The C layer is intentionally thin. Its only job is to get the hardware into a known state and hand off to Lua. It is not the kernel — Nyx is.

### entry.S
RISC-V assembly entry point. Does five things in order: initializes the `gp` (global pointer) register with relaxation temporarily disabled — required for picolibc's linker relaxation to function correctly, without it global variable access silently breaks; sets `sp` to `_stack_top` and aligns it to 16 bytes per the RISC-V ABI; explicitly enables the FPU by setting the FS bits in `mstatus` — required on rv64gc since float instructions will trap until this is done; zeroes BSS using `__bss_start`/`__bss_end`; then calls `boot()`. Halts with `wfi` if `boot()` ever returns.

### boot.c
Initializes the Lua VM via `luaL_newstate()` and `luaL_openlibs()`, registers all hardware globals, validates the ramdisk, loads `nyx/core.lua`, and falls back to a bare C REPL if core.lua ever exits. Boot.c has no boot policy — it does not decide what to launch. That decision belongs to `nyx/core.lua`.

The following globals are registered at boot time and available in every Lua session:

| Global | Description |
|--------|-------------|
| `peek32(addr)` | Read a 32-bit MMIO register |
| `poke32(addr, val)` | Write a 32-bit MMIO register |
| `sysinfo()` | Returns table: arch, heap_kb, ramdisk_files |
| `getchar()` | Read one raw byte from UART |
| `readline()` | Read a line from UART with echo and backspace |
| `prompt()` | Print the `> ` prompt |
| `putstr(s)` | Write raw string to UART, no newline appended |
| `readkey()` | Read one keypress, returns char or named key string |
| `rd_find(path)` | Find a file in the ramdisk, returns string or nil |
| `rd_list()` | List all ramdisk file paths, returns table |
| `virtio_init()` | Initialize VirtIO block device |
| `virtio_read_sector(n)` | Read 512-byte sector from disk |
| `virtio_write_sector(n, data)` | Write 512-byte sector to disk |
| `gpu_init()` | Initialize VirtIO GPU, negotiate framebuffer |
| `fb_ptr()` | Return base address of framebuffer as integer |
| `fb_size()` | Return framebuffer width, height |
| `fb_poke(x, y, rgba)` | Write one pixel to framebuffer |
| `fb_fill(rgba)` | Fill entire framebuffer with one color |
| `fb_flush([x, y, w, h])` | Transfer framebuffer region to display |
| `gpu_debug()` | Return table of GPU/queue diagnostic info |

`putstr` is used by full-screen Lua programs that need precise cursor control. `readkey` handles multi-byte ANSI escape sequences transparently, returning named strings for special keys: UP, DOWN, LEFT, RIGHT, HOME, END, DEL, ESC.

### stubs.c
Picolibc glue and hardware stubs.

**UART I/O** — `uart_putc`/`uart_getc` poll the 16550 LSR register directly. Wired to picolibc stdio via `FDEV_SETUP_STREAM` and assigned to `stdin`/`stdout`/`stderr`. `write()` inserts `\r` before `\n` for terminal compatibility.

**Memory** — `_sbrk` implemented manually with explicit bounds checking against `__heap_end`. Returns `ENOMEM` and `-1` if the heap would overflow rather than silently corrupting memory.

**Timing** — `times()` and `gettimeofday()` are backed by the CLINT `mtime` register at `0x0200bff8`, running at 10MHz. This makes `os.time()` and `os.clock()` return real values rather than zero.

**POSIX stubs** — `open`, `close`, `read`, `write`, `lseek`, `fstat`, `unlink`, `rename` are stubbed to satisfy the linker. `read` on `STDIN_FILENO` is functional via UART. Everything else returns `-1` with an appropriate `errno`.

---

## 4. libc — Picolibc

Selene uses **picolibc** as its C standard library. It is provided by the system toolchain and linked at build time — it is not vendored, submoduled, or compiled as part of the project.

### Why picolibc
- Designed specifically for bare-metal embedded targets
- No OS assumptions baked in
- RISC-V is a first-class target
- Correct stdio model (FILE function pointers) matches what we need

### Installation (Arch Linux)
```bash
sudo pacman -S riscv64-unknown-elf-gcc riscv64-unknown-elf-binutils
yay -S riscv64-unknown-elf-picolibc
sudo pacman -S qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-pci
```

### Heap management
`_sbrk` is implemented in `stubs.c` with bounds checking against `__heap_end` from the linker script. The heap runs from `__heap_start` (immediately after BSS) to `__heap_end` (128MB RAM top minus 64KB stack reservation). Attempting to grow past `__heap_end` returns `ENOMEM` rather than silently overwriting the stack.

---

## 5. Repository Structure

```
selene/
+-- Makefile
+-- linker.ld
+-- entry.S           <- RISC-V entry, stack setup, BSS clear, -> boot()
+-- boot.c            <- VM init, registers globals, hands off to nyx/core.lua
+-- stubs.c           <- picolibc stdio hooks (UART), _sbrk, POSIX stubs
+-- virtio.c          <- VirtIO PCI modern block device driver
+-- virtio_gpu.c      <- VirtIO MMIO GPU driver (legacy v1 transport)
+-- lua/
|   +-- (Lua 5.5 source -- lua.c and luac.c excluded at compile time)
+-- nyx/
|   +-- core.lua      <- Kernel core, boot policy (mount -> init -> recovery)
|   +-- shell.lua     <- Recovery shell + interactive REPL, builtins, /bin/ dispatch
|   +-- fs.lua        <- ext2 driver: superblock, block groups, inodes, allocator
|   +-- proc.lua      <- Process management
|   +-- sched.lua     <- Coroutine scheduler
|   +-- drivers/
|       +-- uart.lua      <- Lua-side UART wrapper
|       +-- virtio.lua    <- Lua-side VirtIO block wrapper (sector read/write)
|       +-- fb.lua        <- Framebuffer text renderer (bitmap font, ANSI terminal)
+-- rootfs/           <- Source of truth for ext2 disk image
|   +-- bin/
|   |   +-- edit.lua      <- Screen editor (ANSI, readkey, putstr)
|   |   +-- ls.lua        <- List directory
|   |   +-- cat.lua       <- Read file
|   |   +-- cp.lua        <- Copy file
|   |   +-- mv.lua        <- Move/rename file
|   |   +-- rm.lua        <- Delete file
|   |   +-- mkdir.lua     <- Create directory
|   |   +-- pwd.lua       <- Print working directory
|   |   +-- cd.lua        <- Change directory
|   |   +-- echo.lua      <- Print arguments
|   |   +-- clear.lua     <- Clear screen
|   |   +-- uname.lua     <- System info
|   |   +-- df.lua        <- Disk usage
|   |   +-- hexdump.lua   <- Hex dump file
|   |   +-- wc.lua        <- Word/line/byte count
|   |   +-- grep.lua      <- Search file by pattern
|   +-- etc/
|   |   +-- init.lua      <- Init system, normal boot path
|   +-- lib/              <- Shared Lua libraries (Phase 4)
|   +-- usr/
|   |   +-- bin/          <- User-installed programs (Phase 4)
|   +-- var/
|   |   +-- log/          <- System logs (Phase 4)
|   +-- home/             <- User home directories, empty at build time
+-- tools/
    +-- mkrd.py       <- Packs nyx/ into SLNE ramdisk binary
```

`rootfs/` is the source of truth for the ext2 disk image. At build time, `make` strips the `rootfs/` prefix and copies all files into the image at their corresponding absolute paths using `e2cp` and `e2mkdir`.

### Why lua.c and luac.c are excluded
Both contain a `main()` function. Since we provide our own entry point via `entry.S` -> `boot()`, including either would cause a linker conflict. The Lua VM is driven directly via `luaL_newstate()` and `luaL_openlibs()`.

---

## 6. Build System

### Toolchain (Arch Linux)
| Tool | Source |
|------|--------|
| `riscv64-unknown-elf-gcc` | `extra/riscv64-unknown-elf-gcc` |
| `riscv64-unknown-elf-binutils` | `extra/riscv64-unknown-elf-binutils` |
| `riscv64-unknown-elf-picolibc` | AUR |
| `qemu-system-riscv64` | `extra/qemu-system-riscv` |
| `qemu-hw-display-virtio-gpu` | `extra/qemu-hw-display-virtio-gpu` |
| `qemu-hw-display-virtio-gpu-pci` | `extra/qemu-hw-display-virtio-gpu-pci` |

### Compiler flags
| Flag | Reason |
|------|--------|
| `-march=rv64gc` | G is IMAFD bundled; gives hardware float, required for `lp64d` ABI |
| `-mabi=lp64d` | Must match rv64gc — mismatch causes picolibc linker errors |
| `-mcmodel=medany` | Required for bare-metal linking at `0x80000000` |
| `--specs=picolibc.specs` | Use picolibc instead of hosted libc |
| `-ffreestanding` | Do not assume a hosted C environment |
| `-nostartfiles` | We provide `entry.S`; do not let picolibc crt0 conflict |

### Build targets
```bash
make          # build selene.elf
make run      # build + launch QEMU with SDL window + serial stdio
make clean    # remove kernel artifacts, preserve disk image
make cleanall # remove everything including disk image
```

### QEMU launch flags
```
qemu-system-riscv64
  -machine virt
  -m 128M
  -bios none
  -kernel selene.elf
  -drive file=selene.img,format=raw,if=none,id=hd0
  -device virtio-blk-pci,drive=hd0
  -device virtio-gpu-device
  -display sdl
  -serial "mon:stdio"
```

`-display sdl` opens a graphical window for the framebuffer. `-serial mon:stdio` keeps UART going to the host terminal for the shell and debug output simultaneously.

---

## 7. Memory Map (QEMU virt)

| Address | Device |
|---------|--------|
| `0x80000000` | RAM start — kernel loads here |
| `0x10000000` | UART0 (16550) |
| `0x10008000` | VirtIO GPU (MMIO, device ID 16) |
| `0x0C000000` | PLIC (interrupt controller) |
| `0x02000000` | CLINT (timer interrupts) |
| `0x30000000` | PCI ECAM config space |
| `0x40000000` | BAR4 assigned address (VirtIO block PCI) |

### VirtIO device layout
VirtIO block uses the PCI modern transport at slot 1 (`0x30008000`), with BAR4 assigned to `0x40000000`. VirtIO GPU uses the MMIO legacy v1 transport at `0x10008000`.

### Address space layout
```
0x80000000  kernel text / data / bss
            heap (__heap_start -> __heap_end)
            ...
            stack (64KB reservation at top)
0x87FFFFFF  top of 128MB RAM

User process virtual space (Sv39, Phase 4):
0x00010000  user text
            user heap
            ...
            user stack
0x3FFFFFFF  user space top
```

---

## 8. Boot Sequence

```
entry.S
  -> boot()
      -> init Lua VM
      -> register all globals
      -> validate ramdisk
      -> load nyx/core.lua
      -> fall back to bare C REPL if core.lua exits

nyx/core.lua
  -> require nyx.fs, nyx.proc, nyx.sched
  -> fs.mount()
      -> success:
          -> _mounted = true
          -> fs.exists("/etc/init.lua") ?
              -> yes: load and run /etc/init.lua
              -> no:  recovery("init not found")
      -> failure:
          -> recovery("mount failed: <err>")

/etc/init.lua  (normal boot path)
  -> print "init: starting Selene"
  -> require("nyx.shell")   <- drops to interactive shell

nyx/shell.lua  (recovery path or via init)
  -> define all builtins
  -> REPL loop
```

If `/etc/init.lua` is missing or errors at any point, `core.lua` drops to the recovery shell with a printed warning. The recovery shell has full access to `fread`, `fwrite`, `fls`, `mount`, and all other builtins regardless of disk state.

---

## 9. Shell

The shell is a Lua REPL. Not bash. Not sh. Lua.

### Philosophy
Every command is a Lua function call. Every return value is a typed Lua value, not stdout text. There is no command parser, no shell syntax sugar, no string soup.

```lua
-- bash equivalent: find . -name "*.lua" | xargs wc -l 2>/dev/null | tail -1
-- Selene:
find("."):filter("%.lua$"):map(lines):sum()
-- returns a number, always works
```

### Dispatch order
The REPL tries three things in order for each input line:

1. `load(line)` and execute — works for all valid Lua including builtin calls
2. If that fails, extract the first word and try `/bin/<word>.lua` from ext2 (only if `_mounted`)
3. If that fails, print the Lua parse error

### Recovery shell builtins (always available)
These builtins are hardcoded in `shell.lua` and work regardless of disk state. They are the minimum required to diagnose and repair a broken system.

```lua
sys()                   -- system info (arch, heap, disk status)
mem()                   -- heap usage
ver()                   -- Selene version string
ps()                    -- process list
mount()                 -- mount ext2 filesystem (guards against double-mount)
rdls()                  -- list ramdisk files
rdread(path)            -- read ramdisk file
run(path, ...)          -- run file (disk first, ramdisk fallback)
cd(path)                -- change working directory (_cwd global)
echo(...)               -- print arguments joined with spaces
fwrite(path, data)      -- write string to disk file
finfo()                 -- filesystem info (block counts, free space)
edit(path)              -- open screen editor (/bin/edit.lua)
help()                  -- tiered help output
```

### Post-mount disk commands (/bin/)
These live on the ext2 filesystem and are loaded via the `/bin/` dispatch mechanism.

```lua
ls(path)                -- list directory (defaults to _cwd)
cat(path)               -- read and print file
cp(src, dst)            -- copy file
mv(src, dst)            -- move/rename file
rm(path)                -- delete file
mkdir(path)             -- create directory
pwd                     -- print working directory
df                      -- disk usage summary
uname                   -- system/version info
clear                   -- clear screen
hexdump(path)           -- hex dump file contents
wc(path)                -- line/word/byte count
grep(pattern, path)     -- search file by Lua pattern
```

### Working directory
`_cwd` is a global string defaulting to `"/"`. `cd` updates it via `rawset(_G, "_cwd", target)` to ensure persistence across chunk boundaries. `ls` and `run` resolve relative paths against `_cwd`.

### help() output tiers
```
always available:
  sys() mem() ver() ps() mount()
  rdls() rdread(path) run(path)
  cd(path) echo(...) fwrite(path, data)
  finfo() edit(path) help()

after mount():
  ls(path) cat(path) finfo() edit(path)
  /bin/<cmd>.lua disk commands
```

---

## 10. Filesystem

### VFS
`nyx/fs.lua` is the filesystem driver. It implements ext2 directly over VirtIO block sector reads/writes. There is no VFS abstraction layer yet — ext2 is the only supported filesystem.

### ext2 implementation
The driver implements: superblock parsing, block group descriptor table, inode read/write, direct block pointers (12 blocks, up to ~12KB per file without indirect), directory entry read/write, block bitmap allocation, inode bitmap allocation, path resolution, and parent directory resolution.

### Public API
```lua
fs.mount()                  -- initialize virtio, parse superblock
fs.read(path)               -- returns file contents as string, or nil, err
fs.write(path, data)        -- create or overwrite file
fs.list(path)               -- returns table of entry names
fs.exists(path)             -- returns bool
fs.mkdir(path)              -- create directory
fs.delete(path)             -- remove file (zeros directory entry)
fs.info()                   -- returns table: block_count, free_blocks,
                            --   inode_count, free_inodes, block_size,
                            --   group_count, blocks_per_group, inodes_per_group
```

### Limitations (current)
- Files larger than 12 blocks (12KB) require indirect block support, not yet implemented
- `fs.delete` zeros the directory entry inode number but does not free the inode or data blocks (no deallocation yet)
- No file permissions enforcement yet
- Single block group assumed for allocation (group 0)

---

## 11. VirtIO Block Driver

`virtio.c` implements the VirtIO PCI modern (version 1) block device driver.

### Transport
PCI slot 1 (`0x30008000`), BAR4 assigned to `0x40000000`. Uses the modern virtio PCI common config layout with separate descriptor, available, and used ring pointers.

### Queue layout
Separate aligned allocations for `VirtqDesc[16]`, `VirtqAvail`, and `VirtqUsed`. Three descriptors per request: header (device reads), data buffer (device reads/writes), status byte (device writes).

### Lua API
```lua
virtio_init()               -- returns true or nil, err
virtio_read_sector(n)       -- returns 512-byte string or nil, err
virtio_write_sector(n, s)   -- returns true or nil, err
```

---

## 12. VirtIO GPU Driver

`virtio_gpu.c` implements the VirtIO MMIO legacy (version 1) GPU driver.

### Transport
MMIO at `0x10008000`, device ID 16. Uses the legacy virtio MMIO transport: `GUEST_PAGE_SIZE`, `QUEUE_NUM`, `QUEUE_ALIGN`, `QUEUE_PFN`. Queue memory is a two-page aligned buffer with descriptors and available ring on page 0, used ring on page 1.

### Initialization sequence
1. Reset device, set ACK + DRIVER status
2. Set `GUEST_PAGE_SIZE` to 4096
3. Negotiate no features
4. Set up control queue (queue 0) via PFN
5. Set DRIVER_OK status
6. `VIRTIO_GPU_CMD_GET_DISPLAY_INFO` — get display resolution
7. `VIRTIO_GPU_CMD_RESOURCE_CREATE_2D` — allocate resource ID 1, RGBA8 format
8. `VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING` — wire static framebuffer array to resource
9. `VIRTIO_GPU_CMD_SET_SCANOUT` — connect resource 1 to scanout 0

### Framebuffer
Static array of `1280 * 800 * 4` bytes, page-aligned, in BSS. Actual dimensions are taken from `GET_DISPLAY_INFO`. The Lua side writes pixels directly via `fb_poke` or `fb_fill`, then calls `fb_flush` to trigger `TRANSFER_TO_HOST_2D` followed by `RESOURCE_FLUSH`.

### Lua API
```lua
gpu_init()                  -- full init sequence, returns true or nil, err
fb_ptr()                    -- framebuffer base address as integer
fb_size()                   -- returns width, height
fb_poke(x, y, rgba)         -- write one pixel (RGBA, 32-bit packed)
fb_fill(rgba)               -- fill entire framebuffer
fb_flush([x, y, w, h])      -- flush region to display (defaults to full screen)
gpu_debug()                 -- diagnostic table (magic, status, avail/used idx)
```

---

## 13. Framebuffer Text Renderer

`nyx/drivers/fb.lua` implements a text terminal on top of the raw framebuffer globals.

### Features
- 8x8 bitmap font covering ASCII 32-126 (full printable set)
- Foreground/background color configurable via `fb.set_colors(fg, bg)`
- Scrolling when cursor reaches bottom of screen
- `fb.install()` replaces the global `print()` with a framebuffer-backed version
- `fb.uninstall()` restores the original `print()`
- `fb.raw_print()` always writes to UART regardless of install state

### API
```lua
local fb = require("nyx.drivers.fb")

fb.init([opts])             -- initialize, optional {install_print=true}
fb.print(...)               -- print to framebuffer
fb.write(str)               -- write string without automatic newline
fb.putc(c)                  -- write one character
fb.clear()                  -- clear screen and reset cursor
fb.redraw()                 -- re-render all lines from buffer
fb.set_colors(fg, bg)       -- set foreground/background RGBA colors
fb.cursor()                 -- returns cx, cy
fb.set_cursor(x, y)         -- move cursor
fb.backspace()              -- delete last character
fb.install()                -- replace global print() with fb.print()
fb.uninstall()              -- restore original print()
fb.raw_print(...)           -- write to UART regardless of install state
```

---

## 14. Nyx Kernel API

Nyx exposes clean Lua-native APIs. POSIX exists only as a compatibility shim.

### Filesystem
```lua
fs.mount()
fs.read(path)
fs.write(path, data)
fs.list(path)
fs.mkdir(path)
fs.delete(path)
fs.exists(path)
fs.info()
```

### Process
```lua
proc.spawn(path, args)      -- returns pid
proc.kill(pid)
proc.exit(code)
proc.list()                 -- returns table of {pid, name, status}
proc.wait(pid)
```

### Memory
```lua
mem.alloc(size)
mem.free(ptr)
mem.info()                  -- returns {total, used, free}
```

### Network (Phase 4)
```lua
net.connect(addr, port)
net.listen(port)
net.send(sock, data)
net.recv(sock)
net.close(sock)
```

---

## 15. Process Model

Each process is an independent Lua VM running in U-mode (Phase 4).

### Current state (Phase 3)
Processes are coroutines within the single kernel VM. `proc.spawn` creates a coroutine. `sched` runs a cooperative round-robin loop. No memory isolation yet.

### Target state (Phase 4)
```
proc.spawn("program.lua", args)
  -> allocate VM state (~300KB-1MB)
  -> load program into new VM
  -> schedule on coroutine scheduler
  -> run in U-mode
  -> on exit/crash: free VM, notify parent
```

### Scheduling
- **Phase 3:** Coroutine-based cooperative multitasking
- **Phase 4:** Preemptive via CLINT timer interrupts

---

## 16. Language Stack

Lua is not just a language here — it is the **execution IR**. Every language that compiles to Lua runs on Selene with zero additional runtime cost. One VM, many languages.

### Tier 1 — Native
| Language | Role |
|----------|------|
| **Lua 5.5** | Base runtime, userspace, scripting |
| **C** | Hardware shim, hot paths, interrupt stubs |

### Tier 2 — Transpile to Lua
| Language | Vibe |
|----------|------|
| **Teal** | Typed kernel development — compiler is one Lua file |
| **Fennel** | Lisp + macros |
| **MoonScript / Yuescript** | CoffeeScript style |
| **Haxe** | Typed, Java-like |
| **TypeScriptToLua** | Full TS type system -> Lua |
| **LunarML** | Standard ML, provably correct systems code |
| **Amulet** | ML/Haskell, algebraic data types |

```
C                 <- bare metal, hot paths, interrupt stubs
Teal              <- drivers, safety-critical kernel code
Lua               <- general purpose, userspace, most things
Fennel            <- if you want Lisp macros
Haxe / TS         <- if you come from those ecosystems
LunarML / Amulet  <- provably correct code
```

---

## 17. POSIX Strategy

Goal: **"POSIX enough for compatibility"**, not strict compliance. The goal is to make existing Lua ecosystem libraries work without modification, not to pass a POSIX test suite.

### What we implement
- File I/O: `open`, `read`, `write`, `close`, `seek`
- Memory: `malloc`, `free` (via picolibc)
- Process: `exit`, minimal stubs
- Enough `stat` for `luafilesystem` to work

### What we skip
- Signals (stub `kill` to return -1)
- Sockets at syscall level (we have `net.*` API)

### Users and groups (Phase 4)
No traditional UID/GID in the kernel. Identity is a Lua-side metadata table owned by Nyx, attached to each process at spawn time: `{ uid = 0, groups = { "wheel", "audio" } }`. Filesystem permission checks consult this table. No passwd file, no shadow database.

---

## 18. Performance

| Concern | Answer |
|---------|--------|
| Lua is slow | Fastest interpreted scripting language. Kernel workloads are I/O dispatch and logic, not compute. |
| No JIT | Fine for now. LuaJIT is a drop-in upgrade path. RISC-V backend in development. |
| GC pauses | Lua 5.5 incremental GC. `lua_gc()` gives manual control. No stop-the-world in ring 0. |
| Hot paths | C FFI. One call, native speed. |
| vs JavaOS | JVM startup + 100MB vs instant boot + ~1MB. Not a competition. |

---

## 19. Development Roadmap

### Phase 1 — Boot
- [x] RISC-V assembly entry point (`entry.S`) — gp init, FPU enable, BSS clear, stack align
- [x] UART driver + picolibc stdio hooks (`stubs.c`)
- [x] CLINT-backed `os.time()` and `os.clock()`
- [x] Lua 5.5 VM boots on rv64gc
- [x] `print()` works over UART
- [x] Interactive REPL with backspace, error recovery
- [x] `peek32` / `poke32` / `sysinfo` registered as kernel globals

*No further changes required for Phase 1.*

### Phase 2 — Foundation
- [x] VFS + ramdisk (flat SLNE format, packed by tools/mkrd.py, linked via objcopy)
- [x] Load nyx/shell.lua from ramdisk at boot
- [x] Coroutine-based process model (nyx/sched.lua)
- [x] Process API (nyx/proc.lua)
- [x] Kernel core (nyx/core.lua)
- [x] Shell builtins: `ls()`, `read(path)`, `run(path)`, `mem()`, `sys()`, `ps()`, `ver()`, `help()`
- [x] UART receive (keyboard input)

### Phase 3 — Usable
- [x] VirtIO block device driver (`virtio.c` + `nyx/drivers/virtio.lua`)
- [x] ext2 filesystem driver (`nyx/fs.lua`)
- [x] VFS wired up
- [x] Writable filesystem
- [x] `/bin/` command search path on ext2 with shell builtins as fallback safety net
- [x] Screen editor (`/bin/edit.lua`) — ANSI cursor control, `readkey()`, `putstr()`, `^S` save, `^Q` quit
- [x] Self-hosting — write, save, and run code entirely from inside Selene
- [x] Recovery shell — tiered help, `_mounted` flag gates post-mount commands
- [x] `/etc/init.lua` init system — boot policy in Lua, not in C
- [x] Core coreutils in `/bin/`: ls, cat, cp, mv, rm, mkdir, cd, pwd, echo, clear, uname, df, hexdump, wc, grep
- [x] VirtIO GPU driver (`virtio_gpu.c`) — MMIO legacy v1, full init sequence
- [x] Framebuffer text renderer (`nyx/drivers/fb.lua`) — 8x8 bitmap font, scrolling, install/uninstall print
- [x] Timer interrupts
- [x] Preemptive scheduler via CLINT timer interrupts
- [ ] Virtual memory (Sv39)
- [ ] Process isolation (U-mode, one Lua VM per process)

### Phase 4 — Ecosystem
- [ ] Package manager (`rocks.install`, `rocks.remove`, `rocks.list`, `rocks.search`)
- [ ] Multi-user support — uid/groups table per process, login, home directories
- [ ] Persistent user sessions
- [ ] Inter-process communication — pass Lua tables between VMs, not raw byte streams
- [ ] VirtIO network driver
- [ ] TCP/IP stack (LuaSocket compatibility layer)
- [ ] TLS (LuaSec)
- [ ] Service supervision — restart crashed processes, dependency ordering

### Phase 5 — Platform
- [ ] Window manager — tiling WM in pure Lua on top of framebuffer
- [ ] Self-hosting compiler toolchain (Teal or Fennel running on Selene)
- [ ] `luarocks` compatibility layer
- [ ] SMP — multiple RISC-V harts
- [ ] USB input via VirtIO HID
- [ ] Audio via VirtIO sound
- [ ] Network-bootable image

---

*"A minimal RISC-V SNK where Lua is the kernel language, C is the hardware shim, and every language that ever thought about targeting Lua runs on the same ~300KB VM, booting in milliseconds, with a graphical framebuffer, a self-hosting filesystem, and a Lua REPL as the shell."*