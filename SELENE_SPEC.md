# Selene Specification
**Version:** 0.3-draft  
**Target:** RISC-V 64-bit (rv64gc), QEMU virt machine (bare metal)  
**Kernel:** Nyx  
**Classification:** Script-Native Kernel (SNK)  

---

## 1. Vision

Selene is a **language-centric bare-metal operating system** where the Lua VM is the universal runtime. The distinction between *OS* and *programming environment* is intentionally minimized — the language is the OS.

> "A tiny JVM-like platform, but for Lua, running directly on bare metal in under 1MB."

Unlike JavaOS (JVM, ~100MB, slow boot) or Singularity (CLR, managed overhead, GC in ring 0), Selene achieves the same "managed runtime as kernel" concept with a ~300KB interpreter, instant boot, and manual GC control.

Selene is a **Script-Native Kernel (SNK)** — a class of OS where a high-level language runtime is not a userspace layer on top of the kernel, but the kernel itself. The SNK model stands alongside the JVM and CLR as a managed-runtime-as-platform concept, differentiated by its radical minimalism and instant boot.

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
│   Lua / Teal / Fennel / Haxe / etc.     │
├─────────────────────────────────────────┤
│   nyx/core.tl (S-mode)                  │  ← Teal-typed kernel logic (Nyx)
│   One trusted kernel Lua VM             │
├─────────────────────────────────────────┤
│   Lua 5.5 VM  (liblua.a)                │  ← Pure ANSI C, ~300KB
├─────────────────────────────────────────┤
│   picolibc (system toolchain)           │  ← Linked at build time, not vendored
│   boot.c | stubs.c                      │  ← C bootstrap + picolibc I/O hooks
├─────────────────────────────────────────┤
│   entry.S (~20 lines RISC-V asm)        │  ← Stack setup, BSS clear, → boot()
├─────────────────────────────────────────┤
│   OpenSBI (M-mode, provided by QEMU)    │
└─────────────────────────────────────────┘
```

### Privilege Model
- **M-mode:** OpenSBI — handles machine-level firmware, we never touch this
- **S-mode:** Nyx kernel — one trusted Lua VM, all kernel logic lives here
- **U-mode:** User processes — one independent Lua VM per process

### Why one VM per process
- Strong crash isolation — a user process dying doesn't touch the kernel VM
- ~300KB–1MB overhead per VM is acceptable on any remotely modern target
- Matches what developers expect from a process model
- Clean security boundary between kernel and user code

---

## 3. The SNK Model

Selene belongs to a class of systems we call **Script-Native Kernels**. The defining property of an SNK is that a high-level managed runtime is not layered on top of a traditional kernel — it *is* the kernel. The C layer exists purely as a hardware shim.

| System | Runtime | Size | Boot | GC model |
|--------|---------|------|------|----------|
| JavaOS | JVM | ~100MB | slow | stop-the-world |
| Singularity | CLR | large | moderate | managed |
| **Selene (SNK)** | **Lua 5.5** | **~1MB** | **instant** | **incremental, manual control** |

The SNK model makes one deliberate trade: raw systems performance for extreme expressiveness and safety at the kernel level. Hot paths always have the C FFI escape hatch.

---

## 4. C Bootstrap Layer

The C layer is intentionally thin. Its only job is to get the hardware into a known state and hand off to the Lua VM. It is not "the kernel" — Nyx is.

### entry.S
RISC-V assembly entry point. Does five things in order: initializes the `gp` (global pointer) register with relaxation temporarily disabled — required for picolibc's linker relaxation to function correctly, without it global variable access silently breaks; sets `sp` to `_stack_top` and aligns it to 16 bytes per the RISC-V ABI; explicitly enables the FPU by setting the FS bits in `mstatus` — required on rv64gc since float instructions will trap until this is done; zeroes BSS using `__bss_start`/`__bss_end`; then calls `boot()`. Halts with `wfi` if `boot()` ever returns.

### boot.c
Initializes the Lua VM via `luaL_newstate()` and `luaL_openlibs()`, registers hardware access globals, then runs the REPL loop entirely in C. The loop reads characters from UART directly via `uart_getc()`, handles backspace, buffers input, and calls `luaL_dostring()` on each completed line. Error messages are printed and the stack is cleaned before the next prompt.

Three globals are registered at boot time and available in every Lua session: `peek32(addr)` reads a 32-bit MMIO register, `poke32(addr, val)` writes one, and `sysinfo()` returns a table containing the target arch string and available heap in KB.

### stubs.c
Picolibc glue and hardware stubs. Contains:

**UART I/O** — `uart_putc`/`uart_getc` poll the 16550 LSR register directly. Wired to picolibc stdio via `FDEV_SETUP_STREAM` and assigned to `stdin`/`stdout`/`stderr`. `write()` also inserts `\r` before `\n` for terminal compatibility.

**Memory** — `_sbrk` implemented manually with explicit bounds checking against `__heap_end`. Returns `ENOMEM` and `-1` if the heap would overflow rather than silently corrupting memory.

**Timing** — `times()` and `gettimeofday()` are backed by the CLINT `mtime` register at `0x0200bff8`, running at 10MHz. This is what makes `os.time()` and `os.clock()` return real values rather than zero.

**POSIX stubs** — `open`, `close`, `read`, `write`, `lseek`, `fstat`, `unlink`, `rename` are all stubbed to satisfy the linker. `read` on `STDIN_FILENO` is functional via UART. Everything else returns `-1` with an appropriate `errno` until the VFS exists.

---

## 5. libc — Picolibc

Selene uses **picolibc** as its C standard library. It is provided by the system toolchain and linked at build time — it is not vendored, submoduled, or compiled as part of the project.

### Why picolibc
- Designed specifically for bare-metal embedded targets
- No OS assumptions baked in
- RISC-V is a first-class target
- Correct stdio model (FILE function pointers) matches what we need
- Ships with a built-in `sbrk` implementation if `__heap_start`/`__heap_end` are defined in the linker script — no need to write our own

### Installation (Arch Linux)
```bash
sudo pacman -S riscv64-unknown-elf-gcc riscv64-unknown-elf-binutils
yay -S riscv64-unknown-elf-picolibc
```

### Heap management
`_sbrk` is implemented manually in `stubs.c` with bounds checking against `__heap_end` from the linker script. The heap runs from `__heap_start` (immediately after BSS) to `__heap_end` (128MB RAM top minus 64KB stack reservation). Attempting to grow past `__heap_end` returns `ENOMEM` rather than silently overwriting the stack.

---

## 6. Repository Structure

```
selene/
├── Makefile
├── linker.ld
├── entry.S          ← RISC-V entry, stack setup, BSS clear, → boot()
├── boot.c           ← VM init, hands off to nyx/
├── stubs.c          ← picolibc stdio hooks (UART), _exit
├── lua/
│   └── (Lua 5.5 source — lua.c and luac.c excluded at compile time)
└── nyx/
    ├── core.tl      ← Teal-typed kernel core (Phase 2+)
    ├── shell.lua    ← Interactive REPL
    ├── fs.lua       ← VFS abstraction
    ├── proc.lua     ← Process management
    ├── sched.lua    ← Coroutine scheduler
    └── drivers/
        ├── uart.lua     ← Lua-side UART wrapper
        ├── fb.lua       ← Framebuffer (Phase 2)
        └── virtio.lua   ← VirtIO block device (Phase 3)
```

### Why lua.c and luac.c are excluded
Both contain a `main()` function. Since we provide our own entry point via `entry.S` → `boot()`, including either would cause a linker conflict. We drive the Lua VM directly via `luaL_newstate()` and `luaL_openlibs()` instead.

---

## 7. Build System

### Toolchain (Arch Linux)
| Tool | Source |
|------|--------|
| `riscv64-unknown-elf-gcc` | `extra/riscv64-unknown-elf-gcc` |
| `riscv64-unknown-elf-binutils` | `extra/riscv64-unknown-elf-binutils` |
| `riscv64-unknown-elf-picolibc` | AUR |
| `qemu-system-riscv64` | `extra/qemu-system-riscv` |

### Compiler flags

| Flag | Reason |
|------|--------|
| `-march=rv64gc` | G is IMAFD bundled; gives hardware float, required for `lp64d` ABI |
| `-mabi=lp64d` | Must match rv64gc — mismatch causes picolibc linker errors |
| `-mcmodel=medany` | Required for bare-metal linking at `0x80000000` |
| `--specs=picolibc.specs` | Use picolibc instead of hosted libc |
| `-ffreestanding` | Don't assume a hosted C environment |
| `-nostartfiles` | We provide `entry.S`; don't let picolibc's crt0 conflict |

### Build targets
```bash
make        # build selene.elf
make run    # build + launch QEMU
make clean  # clean artifacts
```

All Lua sources under `lua/` are compiled except `lua.c` and `luac.c`, which are excluded via a filter in the Makefile since both define `main()`. The output binary is `selene.elf`.

---

## 8. Memory Map (QEMU virt)

| Address | Device |
|---------|--------|
| `0x80000000` | RAM start — kernel loads here |
| `0x10000000` | UART0 (16550) |
| `0x0C000000` | PLIC (interrupt controller) |
| `0x02000000` | CLINT (timer interrupts) |

### Address space layout
```
0x80000000  kernel text / data / bss
            ↓ heap (__heap_start → __heap_end)
            ...
            ↑ stack (64KB reservation at top)
0x87FFFFFF  top of 128MB RAM

User process virtual space (Sv39, Phase 3):
0x00010000  user text
            ↓ user heap
            ...
            ↑ user stack
0x3FFFFFFF  user space top
```

---

## 9. Language Stack

Lua is not just a language here — it is the **execution IR**. Every language that compiles to Lua runs on Selene with zero additional runtime cost. One VM, many languages.

### Tier 1 — Native
| Language | Role |
|----------|------|
| **Lua 5.5** | Base runtime, userspace, scripting |
| **Teal** | Typed kernel development — compiler is one Lua file, ships free |
| **C** | Hardware shim, hot paths, interrupt stubs |

### Tier 2 — Transpile to Lua
| Language | Vibe |
|----------|------|
| **Fennel** | Lisp + macros, popular in Neovim/gamedev |
| **MoonScript / Yuescript** | CoffeeScript style, powers itch.io |
| **Haxe** | Typed, Java-like, used in Dead Cells |
| **TypeScriptToLua** | Full TS type system → Lua |
| **LunarML** | Standard ML, provably correct systems code |
| **Amulet** | ML/Haskell, algebraic data types |

### The language pyramid
```
C                 ← bare metal, hot paths, interrupt stubs
Teal              ← kernel (Nyx), drivers, safety-critical
Lua               ← general purpose, userspace, most things
Fennel            ← if you want Lisp macros
Haxe / TS         ← if you come from those ecosystems
LunarML / Amulet  ← provably correct code
```

Every single one runs on the same ~300KB VM. Zero additional runtime overhead.

---

## 10. Nyx Kernel API

Nyx exposes clean Lua-native APIs. POSIX exists only as a compatibility shim for ecosystem libraries.

### Filesystem
```lua
fs.read(path)
fs.write(path, data)
fs.list(path)           -- returns table
fs.mkdir(path)
fs.delete(path)
fs.exists(path)         -- returns bool
fs.mount(device, path)
```

### Process
```lua
proc.spawn(path, args)  -- returns pid
proc.kill(pid)
proc.exit(code)
proc.list()             -- returns table of {pid, name, status}
proc.wait(pid)
```

### Memory
```lua
mem.alloc(size)
mem.free(ptr)
mem.info()              -- returns {total, used, free}
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

## 11. Shell

The shell is a Lua REPL. Not bash. Not sh. Lua.

### Philosophy
Bash is string soup. It was never designed to be a programming language and it shows. Every command in Selene returns actual typed Lua data, not stdout text.

```lua
-- bash: find . -name "*.lua" | xargs wc -l 2>/dev/null | tail -1
-- (pray spaces don't break it)

-- Selene:
find("."):filter("%.lua$"):map(lines):sum()
-- returns a number. always works.
```

### Shell sugar
```lua
$ ls            -- fs.list(".")
$ cd /home      -- fs.cd("/home")
$ cat file      -- fs.read("file") |> print
$ run script    -- dofile("script.lua")
```

Everything else is pure Lua. No mode switching. The shell IS the scripting language.

### Error handling
```lua
local ok, err = pcall(dangerous_command)
if not ok then
    print("failed:", err.message, err.code)
end
```

### Scripting
Any `.lua` file is a shell script. Any `.tl` file compiles via the bundled Teal compiler and runs. No shebangs, no chmod, no magic.

---

## 12. Process Model

Each process is an independent Lua VM running in U-mode.

### Lifecycle
```
proc.spawn("program.lua", args)
  → allocate VM state (~300KB–1MB)
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

## 13. Concurrency Model

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

## 14. POSIX Strategy

Goal: **"POSIX enough for compatibility"**, not strict compliance. The goal is to make existing Lua ecosystem libraries work without modification, not to pass a POSIX test suite.

### What we implement
- File I/O: `open`, `read`, `write`, `close`, `seek`
- Memory: `malloc`, `free` (via picolibc)
- Process: `exit`, minimal stubs
- Enough `stat` for `luafilesystem` to work

### What we skip
- Signals (stub `kill` to return -1)
- Sockets at syscall level (we have `net.*` API)

### Users and groups (Phase 3)
No traditional UID/GID in the kernel. Identity is a Lua-side metadata table owned by Nyx, attached to each process at spawn time. A process carries a table of the form `{ uid = 0, groups = { "wheel", "audio" } }` and filesystem permission checks consult it. No passwd file, no shadow database — just a Nyx-owned table the kernel controls. Sufficient for multi-user semantics without any POSIX baggage. Adding real persistence (a users file on the VFS) is a straightforward Phase 3 extension once the VFS exists.

---

## 15. Bundled Libraries

### Ships with Selene
| Library | Purpose |
|---------|---------|
| `tl.lua` | Teal compiler (single Lua file, free) |
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

---

## 16. Package Manager

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

Installing a package = putting `.lua` files on the path. The package manager itself is ~100 lines of Lua.

---

## 17. Performance

| Concern | Answer |
|---------|--------|
| Lua is slow | Fastest interpreted scripting language. Kernel workloads are I/O dispatch and logic, not compute. |
| No JIT | Fine for now. LuaJIT is a drop-in upgrade. RISC-V backend in development. |
| GC pauses | Lua 5.5 incremental GC. `lua_gc()` gives manual control. No stop-the-world in ring 0. |
| Hot paths | C FFI. One call. Native speed. |
| vs JavaOS | JVM startup + 100MB vs instant boot + ~1MB. Not a competition. |

---

## 18. Self-Hosting

The Teal compiler is a single Lua file. It ships inside Selene. You can write, compile, and run Selene software from inside Selene with zero external toolchain. This is the Forth insight applied forward: the OS and its development environment are the same thing.

---

## 19. Development Roadmap

### Phase 1 — Boot *(complete)*
- [x] RISC-V assembly entry point (`entry.S`) — gp init, FPU enable, BSS clear, stack align
- [x] UART driver + picolibc stdio hooks (`stubs.c`)
- [x] CLINT-backed `os.time()` and `os.clock()`
- [x] Lua 5.5 VM boots on rv64gc
- [x] `print()` works over UART
- [x] Interactive REPL with backspace, error recovery
- [x] `peek32` / `poke32` / `sysinfo` registered as kernel globals

### Phase 2 — Foundation
- [ ] Timer interrupts (CLINT)
- [ ] UART receive (keyboard input)
- [ ] VFS + ramdisk
- [ ] Load `nyx/core.tl` from ramdisk
- [ ] Coroutine-based process model
- [ ] Teal bundled

### Phase 3 — Usable
- [ ] Framebuffer
- [ ] Package manager
- [ ] Preemptive scheduler
- [ ] Virtual memory (Sv39)
- [ ] Process isolation (U-mode)

### Phase 4 — Ecosystem
- [ ] LuaJIT RISC-V backend
- [ ] Network stack
- [ ] Self-hosting

---

*"A minimal RISC-V SNK where Lua is the kernel language, Teal gives you type safety, C is the hardware shim, and every language that ever thought about targeting Lua runs on the same ~300KB VM, booting in milliseconds, in under 1MB total."*