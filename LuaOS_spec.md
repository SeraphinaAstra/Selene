# LuaOS Specification
**Version:** 0.2-draft  
**Target:** RISC-V 64-bit (rv64imac), QEMU virt machine (bare metal)  
**Author:** SerArch  

---

## 1. Vision

LuaOS is a **language-centric bare-metal operating system** where the Lua VM is the universal runtime. The distinction between *OS* and *programming environment* is intentionally minimized — the language is the OS.

> "A tiny JVM-like platform, but for Lua, running directly on bare metal in under 1MB."

Unlike JavaOS (JVM, ~100MB, slow boot) or Singularity (CLR, managed overhead, GC in ring 0), LuaOS achieves the same "managed runtime as kernel" concept with a 300KB interpreter, instant boot, and manual GC control.

### Design Principles
- **Minimal core, maximal leverage** — reuse the Lua ecosystem instead of rebuilding it
- **Language-first, OS-second** — the runtime IS the value proposition
- **Pragmatism over purity** — POSIX-ish is fine, strict compliance is not the goal
- **Fast iteration over premature complexity** — get to a working REPL, then build
- **Separation of concerns via privilege modes, not language boundaries**
- **Lua is the brain, C is the muscle**

---

## 2. Architecture

### Execution Model
```
┌─────────────────────────────────────────┐
│   Userspace processes (U-mode)          │  ← One Lua VM per process
│   Lua / Teal / Haxe / Fennel / etc.     │
├─────────────────────────────────────────┤
│   kernel.lua (S-mode)                   │  ← Teal-typed kernel logic
│   One trusted kernel Lua VM             │
├─────────────────────────────────────────┤
│   Lua 5.5 VM  (liblua.a)                │  ← Pure ANSI C, ~300KB
├─────────────────────────────────────────┤
│   lualibc (custom libc)                 │  ← Our own, not newlib
│   uart.c | memory.c | syscalls.c        │
├─────────────────────────────────────────┤
│   boot.S (~10 lines RISC-V asm)         │
├─────────────────────────────────────────┤
│   OpenSBI (M-mode, provided by QEMU)    │
└─────────────────────────────────────────┘
```

### Privilege Model
- **M-mode:** OpenSBI — handles machine-level firmware, we never touch this
- **S-mode:** LuaOS kernel — one trusted Lua VM, all kernel logic lives here
- **U-mode:** User processes — one independent Lua VM per process

### Why one VM per process
- Strong crash isolation — a user process dying doesn't touch the kernel VM
- ~300KB–1MB overhead per VM is negligible on any remotely modern system
- Matches what developers expect from a process model
- Clean security boundary between kernel and user code

---

## 3. Custom libc — lualibc

Newlib is not used. We write our own minimal libc (`lualibc`) tailored exactly to what the Lua VM needs and nothing else.

### Why not newlib
- Newlib assumes things about the environment we don't want to provide
- ABI mismatch issues on bare metal
- We only need ~15 functions. Newlib ships thousands.
- Writing our own means we understand every line of the C layer

### Exact libc surface Lua 5.5 needs

Lua 5.5 is written in strict ANSI C89/C90 and needs roughly **40-50 libc functions** for the full stdlib, or as few as **15-20** for a minimal "Hello World" boot. This is entirely manageable.

#### Tier 1 — Absolute minimum (core VM only, no stdlib)
```c
// memory — lua_newstate takes a custom allocator, removing malloc entirely
malloc, realloc, free

// string
memcpy, memmove, memset, strlen, strchr, strcmp

// error handling — Lua's exception system is built on these
setjmp, longjmp

// types only (header-only, no implementation needed)
limits.h, stddef.h, stdarg.h
```
**~15 functions.** This is enough to boot the VM and run Lua code.

#### Tier 2 — Full stdlib (what we actually want)
```c
// I/O  (liolib.c) — hooked to our VFS
fopen, fclose, fread, fwrite, fflush, fseek, ftell, setvbuf, remove, rename

// Math (lmathlib.c) — delegated to libgcc soft-float
sin, cos, tan, asin, acos, atan, ceil, floor, fmod, pow, sqrt, exp, log

// OS   (loslib.c) — mostly stubbed, we don't have a real OS clock yet
exit, getenv, clock, time, strftime, difftime

// String extras (lstrlib.c)
strpbrk, strcspn, strstr, sprintf, strncpy, strcmp

// Character classification (lctype.c — Lua has its own, but uses these as fallback)
isdigit, isspace, isalpha, isalnum, iscntrl, isxdigit
```
**~45 functions total.** Still very manageable.

#### Lua 5.5 specific notes
- `lua_newstate` accepts a **custom allocator function** — we pass our own, completely bypassing `malloc` if we want
- `lmathlib.c` can be **excluded entirely** from the build if we don't need math (we do, but it's optional)
- The new **external strings** feature may need custom alloc/dealloc hooks if used
- `luaL_makeseed` needs a randomness source — stub it with a fixed seed for now, fix later

### lualibc structure
```
libs/lualibc/
├── include/
│   ├── stdlib.h       ← malloc, free, realloc, exit, getenv (stub)
│   ├── string.h       ← memcpy, memmove, memset, strlen, strcmp, etc.
│   ├── stdio.h        ← fopen/fclose/fread/fwrite hooked to VFS + UART
│   ├── math.h         ← delegates to libgcc soft-float intrinsics
│   ├── setjmp.h       ← declares setjmp/longjmp
│   ├── ctype.h        ← isdigit, isspace, isalpha, etc.
│   ├── time.h         ← clock, time (stubbed for now)
│   └── stdint.h / stddef.h / stdarg.h / stdbool.h  ← header-only
├── src/
│   ├── malloc.c       ← Phase 1: bump allocator. Phase 2: buddy allocator.
│   ├── string.c       ← all string.h implementations
│   ├── stdio.c        ← printf → UART, fopen/fread/fwrite → VFS stubs
│   ├── ctype.c        ← character classification lookup table
│   ├── math.c         ← thin wrappers over libgcc __adddf3 etc.
│   ├── time.c         ← stubbed, returns 0 until we have a timer
│   └── setjmp.S       ← RISC-V assembly, critical for Lua error handling
└── lualibc.a
```

### malloc strategy
- **Phase 1:** Bump allocator — pointer starts at `_bss_end`, increments on alloc, `free` is a no-op. Zero complexity, zero bugs, works for bootstrapping.
- **Phase 2:** Replace with buddy allocator once the kernel is stable. Interface stays identical, Lua never knows the difference.
- **Alternative:** Pass a custom allocator directly to `lua_newstate` and bypass libc malloc entirely for the VM. Best of both worlds for the kernel VM specifically.

---

## 4. Repository Structure

```
LuaOS/
├── Makefile
├── linker.ld
├── LuaOS_spec.md
│
├── boot/
│   └── boot.S                  ← stack setup, BSS zero, → kernel_main
│
├── kernel/
│   ├── kernel.c                ← VM init, load kernel.lua
│   ├── uart.c / uart.h         ← 16550 UART @ 0x10000000
│   ├── memory.c / memory.h     ← physical memory manager
│   ├── interrupts.c            ← PLIC + CLINT handlers (Phase 2)
│   └── trap.S                  ← RISC-V trap vector (Phase 2)
│
├── libs/
│   └── lualibc/                ← custom libc
│       ├── include/
│       └── src/
│
├── lua/
│   └── (Lua 5.5 source, compiled as liblua.a)
│
└── src/
    ├── kernel.tl               ← Teal-typed kernel core
    ├── shell.lua               ← Interactive REPL
    ├── fs.lua                  ← VFS abstraction
    ├── proc.lua                ← Process management
    ├── sched.lua               ← Coroutine scheduler
    ├── drivers/
    │   ├── uart.lua            ← Lua-side UART wrapper
    │   ├── fb.lua              ← Framebuffer (Phase 2)
    │   └── virtio.lua          ← VirtIO block device (Phase 3)
    └── pkg/
        └── rocks.lua           ← Package manager
```

---

## 5. Memory Map (QEMU virt)

| Address | Device |
|---------|--------|
| `0x80000000` | RAM start — kernel loads here |
| `0x10000000` | UART0 (16550) |
| `0x0C000000` | PLIC (interrupt controller) |
| `0x02000000` | CLINT (timer interrupts) |
| `0x80000000 + 128MB` | Stack top |

### Address space layout (eventual)
```
0x80000000  kernel text/data/bss
            ↓ kernel heap (lualibc malloc)
            ...
            ↑ kernel stack
0x87FFFFFF  top of 128MB RAM

User process virtual space (Sv39, Phase 3):
0x00010000  user text
            ↓ user heap
            ...
            ↑ user stack
0x3FFFFFFF  user space top
```

---

## 6. Language Stack

Lua is not just a language here — it is the **execution IR**. Every language that compiles to Lua runs on LuaOS with zero additional runtime cost. One VM, infinite languages.

### Tier 1 — Native
| Language | Role |
|----------|------|
| **Lua 5.5** | The base runtime, userspace, scripting |
| **Teal** | Typed kernel development (compiler = one Lua file, ships free) |
| **C** (via FFI) | Bare metal escape hatch, hot paths, interrupt stubs |

### Tier 2 — Transpile to Lua
| Language | Vibe | Notable |
|----------|------|---------|
| **Fennel** | Lisp + macros | Popular in Neovim/gamedev, full macro system |
| **Urn** | Purist functional Lisp | Heavy compile-time optimization |
| **MoonScript / Yuescript** | CoffeeScript style | Powers itch.io in production |
| **Haxe** | Typed, Java-like | Used in Dead Cells, huge stdlib |
| **TypeScriptToLua** | TypeScript | Full TS type system → Lua |
| **CSharp.lua** | C# | C# syntax compiling to Lua |
| **LunarML** | Standard ML | Provably correct systems code |
| **Amulet** | ML/Haskell | Algebraic data types, type inference |
| **GopherLua / Gi** | Go-like | Go syntax on the Lua VM |
| **p2lua** | Pascal | Pascal → Lua transpiler |
| **Ruia / Ruby2Lua** | Ruby | Ruby syntax → Lua |
| **RPy / Python-to-Luau** | Python subset | Python-flavored Lua target |

### The language pyramid
```
C FFI             ← bare metal, hot paths, interrupt stubs
Teal              ← kernel, drivers, safety-critical
Lua               ← general purpose, userspace, most things
Fennel / Urn      ← if you want Lisp macros
Haxe / TS / C#    ← if you come from those ecosystems
LunarML / Amulet  ← provably correct code
Go / Python / Ruby ← if you really want to
```

Every single one of these runs on the same 300KB VM. Zero additional runtime.

### What this makes LuaOS
LuaOS is a **universal language runtime platform** — conceptually similar to the JVM or CLR, but 300KB instead of 100MB+, instant boot, bare metal, no stop-the-world GC.

---

## 7. Kernel API (Lua-native)

The kernel exposes clean Lua-native APIs. POSIX exists only as a compatibility shim.

### Filesystem
```lua
fs.read(path)
fs.write(path, data)
fs.list(path)          -- returns table
fs.mkdir(path)
fs.delete(path)
fs.exists(path)        -- returns bool
fs.mount(device, path)
```

### Process
```lua
proc.spawn(path, args) -- returns pid
proc.kill(pid)
proc.exit(code)
proc.list()            -- returns table of {pid, name, status}
proc.wait(pid)
```

### Memory
```lua
mem.alloc(size)
mem.free(ptr)
mem.info()             -- returns {total, used, free}
```

### Network (Phase 3)
```lua
net.connect(addr, port)
net.listen(port)
net.send(sock, data)
net.recv(sock)
net.close(sock)
```

---

## 8. Shell

The shell is a Lua REPL with minimal sugar. Not bash. Not sh. Lua.

### Philosophy
Bash is string soup. It was never designed to be a programming language and it shows. Every command in LuaOS returns actual typed Lua data, not stdout text.

```lua
-- bash: find . -name "*.lua" | xargs wc -l 2>/dev/null | tail -1
-- (pray spaces don't break it)

-- LuaOS:
find("."):filter("%.lua$"):map(lines):sum()
-- returns a number. always works.
```

### Shell sugar
```lua
$ ls              -- fs.ls()
$ cd /home        -- fs.cd("/home")
$ cat file        -- fs.read("file") |> print
$ run script.lua  -- dofile("script.lua")
```

Everything else is pure Lua. No mode switching. The shell IS the scripting language.

### Error handling
```lua
-- bash: command || echo "failed" && exit 1

-- LuaOS:
local ok, err = pcall(dangerous_command)
if not ok then
    print("failed:", err.message, err.code)
end
```

### Scripting
Any `.lua` file is a shell script. Any `.tl` file compiles via bundled Teal and runs. No shebangs, no chmod, no magic.

---

## 9. Process Model

Each process is an independent Lua VM running in U-mode.

### Lifecycle
```
proc.spawn("program.lua", args)
  → allocate VM state (~300KB-1MB)
  → load program into new VM
  → schedule on coroutine scheduler
  → run in U-mode
  → on exit/crash: free VM, notify parent
```

### Scheduling
- **Phase 1:** Coroutine-based cooperative multitasking
- **Phase 2:** Preemptive via CLINT timer interrupts

```
Timer interrupt (C trap handler)
  → save current process state
  → call sched.next() in kernel VM
  → restore next process state
  → return to U-mode
```

---

## 10. POSIX Strategy

Goal: **"POSIX enough for compatibility"**, not strict compliance.

Behavior matters more than correctness. The goal is to make existing Lua ecosystem libraries work without modification, not to pass a POSIX test suite.

### What we implement
- File I/O: `open`, `read`, `write`, `close`, `seek`
- Memory: `malloc`, `free` (via lualibc)
- Process: `exit`, minimal stubs
- Enough `stat` for `luafilesystem` to work

### What we skip
- Signals (stub `kill` to return -1)
- Users/groups (everything is root, single-user OS)
- Sockets at syscall level (we have `net.*` API)

---

## 11. Concurrency Model

### Phase 1 — Cooperative
Lua coroutines. Each process is a coroutine. Explicit yields between operations.

```lua
local function scheduler()
    while true do
        for _, proc in ipairs(process_table) do
            if proc.status == "ready" then
                coroutine.resume(proc.co)
            end
        end
        coroutine.yield()
    end
end
```

### Phase 2 — Preemptive
Timer interrupts via CLINT. C trap handler saves state, calls Lua scheduler, restores next process.

### Event model
```
Hardware interrupt → C trap handler → event queued in kernel VM
                                     → Lua scheduler wakes relevant process
                                     → process handles event in Lua
```

---

## 12. Bundled Libraries

### Ships with LuaOS
| Library | Purpose |
|---------|---------|
| `tl.lua` | Teal compiler (free — single Lua file) |
| `lua-cjson` | JSON |
| `Penlight` | Extended stdlib, path handling, OOP |
| `lpeg` | Parsing expression grammars |
| `luafilesystem` | Filesystem ops |

### Available via package manager
| Library | Purpose |
|---------|---------|
| `LuaSocket` | Networking |
| `LuaSec` | TLS |
| `lsqlite3` | SQLite |
| `lua-zlib` | Compression |
| `busted` | Testing |
| `cqueues` | Async I/O |

### Graphics (Phase 2+)
| Library | Purpose |
|---------|---------|
| `fb.lua` | Raw framebuffer driver |
| LÖVE-inspired API | 2D graphics, sprites, canvas |

---

## 13. Package Manager

```lua
rocks.install("package")
rocks.remove("package")
rocks.update()
rocks.list()
rocks.search("query")
```

Package manifest:
```lua
return {
    name    = "lua-cjson",
    version = "2.1.0",
    deps    = {},
    files   = { "cjson.lua" }
}
```

Installing a package = putting `.lua` files on the path. Package manager itself is ~100 lines of Lua.

---

## 14. Build System

### Toolchain (Arch Linux)
| Tool | Package |
|------|---------|
| `riscv64-elf-gcc` | `extra/riscv64-elf-gcc` |
| `riscv64-elf-binutils` | `extra/riscv64-elf-binutils` |
| `qemu-system-riscv64` | `extra/qemu-arch-extra` |

### Compiler flags
```makefile
CROSS  = riscv64-elf-
ARCH   = -march=rv64imac -mabi=lp64
CFLAGS = $(ARCH) -ffreestanding -O2 -Wall \
         -Ikernel -Ilua -Ilibs/lualibc/include
```

### Build targets
```bash
make        # build luaos.elf
make run    # build + launch QEMU
make clean  # clean artifacts
```

---

## 15. Development Roadmap

### Phase 1 — Boot *(current)*
- [x] RISC-V assembly bootloader
- [x] UART driver (16550)
- [x] Lua VM compiles for rv64imac
- [ ] lualibc (replace newlib)
- [ ] Lua VM boots, runs kernel.lua
- [ ] `print()` works over UART
- [ ] Basic Lua REPL

### Phase 2 — Foundation
- [ ] Timer interrupts (CLINT)
- [ ] UART receive (keyboard input)
- [ ] VFS + ramdisk
- [ ] Coroutine-based process model
- [ ] Teal bundled

### Phase 3 — Usable
- [ ] Framebuffer
- [ ] Package manager
- [ ] Preemptive scheduler
- [ ] Virtual memory (Sv39)
- [ ] Process isolation

### Phase 4 — Ecosystem
- [ ] LuaJIT RISC-V backend
- [ ] Network stack
- [ ] Self-hosting

---

## 16. Performance

| Concern | Answer |
|---------|--------|
| Lua is slow | Fastest interpreted scripting language. Kernel workloads are I/O dispatch and logic, not compute. |
| No JIT | Fine for now. LuaJIT is a drop-in upgrade. RISC-V backend in development. |
| GC pauses | Lua 5.5 incremental GC. `lua_gc()` gives manual control. No stop-the-world in ring 0. |
| Hot paths | C FFI. One call. Native speed. |
| vs JavaOS | JVM startup + 100MB vs instant boot + 1MB. Not a competition. |

---

## 17. Self-Hosting

The Teal compiler is a single Lua file. It ships inside the OS. You can write, compile, and run LuaOS software from inside LuaOS with zero external toolchain.

This is the Forth insight applied forward: the OS and its development environment are the same thing.

---

*"A minimal RISC-V OS where Lua is the kernel language, Teal gives you type safety, C is the escape hatch, and every language that ever thought about targeting Lua — TypeScript, C#, Go, Python, Ruby, Standard ML, Haskell, Lisp, and more — runs on the same 300KB VM, booting in milliseconds, in under 1MB total."*