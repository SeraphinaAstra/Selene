# LuaOS Specification
**Version:** 0.1-draft  
**Target:** RISC-V 64-bit (rv64imac), QEMU virt machine  
**Author:** SerArch  

---

## 1. Concept

LuaOS is a bare-metal operating system for RISC-V where **Lua 5.5 is the kernel language**. The architecture is a minimal C runtime that boots the Lua VM, after which the entire OS — shell, drivers, filesystem, package manager, userspace — is written in Lua (or any language that compiles to Lua).

The philosophy is identical to old Forth-based systems: **the language is the OS**. The shell is a Lua REPL. Scripts are Lua programs. Drivers are Lua modules. There is no context switch between "using the OS" and "programming the OS."

### Why this works
- Lua 5.5 interpreter + stdlib = ~300KB of pure ANSI C, trivially portable
- newlib + Lua statically linked = under 1MB total footprint
- Lua is the fastest interpreted scripting language available
- Lua's `lua_Alloc` is a single C function — the entire memory manager is one hook
- Incremental GC (Lua 5.5) means no stop-the-world pauses in kernel code
- The Lua VM is a near-universal compile target with a rich ecosystem of languages

### Comparison
| OS | Language | Runtime size | Boot time |
|----|----------|-------------|-----------|
| JavaOS | Java | ~100MB (JVM) | Slow |
| Singularity | C# | ~50MB (CLR) | Slow |
| **LuaOS** | **Lua** | **~1MB** | **Instant** |

---

## 2. Architecture

```
┌─────────────────────────────────────┐
│         Userspace / Shell           │  ← Pure Lua / any Lua-targeting lang
├─────────────────────────────────────┤
│         kernel.lua                  │  ← Teal-typed Lua kernel logic
├─────────────────────────────────────┤
│         Lua 5.5 VM (liblua.a)       │  ← C, compiled for rv64imac
├─────────────────────────────────────┤
│   newlib | uart.c | syscalls.c      │  ← Thin C glue layer
├─────────────────────────────────────┤
│         boot.S                      │  ← ~10 lines of RISC-V asm
├─────────────────────────────────────┤
│   OpenSBI (M-mode firmware)         │  ← Provided by QEMU
├─────────────────────────────────────┤
│   RISC-V hardware / QEMU virt       │
└─────────────────────────────────────┘
```

### Boot sequence
1. QEMU loads `luaos.elf` at `0x80000000`
2. `boot.S` sets up stack, zeroes BSS, calls `kernel_main()`
3. `kernel_main()` inits UART, inits newlib memory, creates Lua VM
4. Lua VM loads `kernel.lua`
5. `kernel.lua` starts the shell — you are now in Lua

---

## 3. Language Stack

LuaOS supports **any language that compiles to Lua** with zero additional runtime cost. Everything runs on the same 300KB VM.

### Tier 1 — Native (always available)
| Language | Description | Use case |
|----------|-------------|----------|
| **Lua 5.5** | The base language | General purpose, userspace, scripting |
| **Teal** | Typed Lua (TypeScript analogy) | Kernel code, drivers, safety-critical paths |
| **C** (via FFI) | Direct hardware access | Hot paths, interrupt stubs, bare metal ops |

### Tier 2 — Transpile-to-Lua
| Language | Vibe | Use case |
|----------|------|----------|
| **Fennel** | Lisp with macros | Metaprogramming, DSLs, macro-heavy code |
| **Urn** | Functional Lisp | Purist functional programming |
| **MoonScript / Yuescript** | CoffeeScript for Lua | Concise OOP-style code (powers itch.io) |
| **Haxe** | Typed, Java-like | Large projects, cross-platform code |
| **Amulet** | ML/Haskell style | Functional, algebraic data types |
| **LunarML** | Standard ML | Provably correct systems code |

### The language pyramid
```
C FFI          ← when you need bare metal right now
Teal           ← when correctness is life-or-death (kernel)
Lua            ← when you just want to get things done
Fennel/Haxe/ML ← when you have opinions about programming languages
```

All of these compile to Lua bytecode. Same VM. Zero overhead.

### Teal's role
Teal is the **kernel development language**. Its compiler (`tl.lua`) is a single dependency-free Lua file, meaning **the compiler ships inside the OS for free**.

```teal
-- type checked driver interface, compile-time safety
local record UARTDevice
    base_addr: integer
    baud_rate: integer
    write: function(self: UARTDevice, data: string)
    read: function(self: UARTDevice): string
end
```

Type errors in kernel code are caught at compile time. At runtime it's just Lua.

---

## 4. Repository Structure

```
LuaOS/
├── Makefile                  ← Root build system
├── linker.ld                 ← Memory layout (loads at 0x80000000)
├── LuaOS_spec.md             ← This document
│
├── boot/
│   └── boot.S                ← Assembly stub: stack setup, BSS zero, call kernel_main
│
├── kernel/
│   ├── kernel.c              ← Entry point: init VM, load kernel.lua
│   ├── uart.c / uart.h       ← 16550 UART driver (QEMU virt @ 0x10000000)
│   ├── memory.c / memory.h   ← Memory manager (newlib sbrk stub → future PMM)
│   ├── syscalls.c            ← Newlib syscall stubs (_sbrk, _write→UART, etc.)
│   └── interrupts.c          ← (Phase 2) PLIC + timer interrupt handlers
│
├── lua/
│   └── (Lua 5.5 source tree, compiled as liblua.a)
│
├── src/
│   ├── kernel.lua            ← Main kernel logic (Teal-typed)
│   ├── shell.lua             ← Interactive Lua REPL shell
│   ├── fs.lua                ← Filesystem abstraction
│   ├── drivers/
│   │   ├── uart.lua          ← Lua-side UART wrapper
│   │   └── fb.lua            ← Framebuffer driver (Phase 2)
│   └── pkg/
│       └── rocks.lua         ← Package manager
│
└── libs/
    └── (custom C binding libraries)
```

---

## 5. Memory Map (QEMU virt)

| Address | Device |
|---------|--------|
| `0x80000000` | RAM start — kernel loads here |
| `0x10000000` | UART0 (16550) |
| `0x0C000000` | PLIC (interrupt controller) |
| `0x02000000` | CLINT (timer) |
| `0x80000000 + 128MB` | Stack top |

---

## 6. Build System

### Toolchain
| Tool | Package |
|------|---------|
| Compiler | `riscv64-elf-gcc` (Arch: `extra/riscv64-elf-gcc`) |
| Binutils | `riscv64-elf-binutils` |
| C library | `riscv64-elf-newlib` (at `/usr/riscv64-elf/lib/rv64imac/lp64/`) |
| Emulator | `qemu-system-riscv64` |

### Build targets
```bash
make          # build luaos.elf
make run      # build and launch in QEMU
make clean    # clean all build artifacts
```

### Compiler flags
```
-march=rv64imac -mabi=lp64    # RISC-V 64-bit, integer ABI, no FPU
-ffreestanding                # no host OS assumptions
-nostdlib                     # we provide our own libc (newlib)
```

---

## 7. C Layer Details

The C layer has one job: **get the Lua VM running**. It is not the kernel. It is the VM host.

### syscalls.c — Newlib integration
Newlib requires syscall stubs to link. Key ones:
- `_sbrk` — bump allocator starting at `_bss_end`, feeds `malloc`
- `_write` — routes to `uart_putc`, making `printf` work
- All others are no-ops or return -1

### uart.c — 16550 UART
QEMU virt exposes a 16550-compatible UART at `0x10000000`. Polling-based for now (no interrupts until Phase 2). This is how `print()` works in the kernel.

### kernel.c — VM init
```c
void kernel_main(void) {
    uart_init();
    memory_init();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    luaL_dofile(L, "kernel.lua");  // hand off to Lua forever
    while(1);
}
```

After `luaL_openlibs`, the entire Lua stdlib is available. After `luaL_dofile`, we are in Lua. The C layer is done.

---

## 8. Lua Standard Libraries (built-in)

These ship with Lua 5.5 and are available from boot with zero additional code:

| Library | What it gives us |
|---------|-----------------|
| `base` | print, pcall, type, pairs, ipairs, load, etc. |
| `math` | Full math library |
| `string` | String manipulation |
| `table` | Table utilities |
| `io` | File I/O (hooked to our VFS) |
| `os` | OS interface (stubbed, we implement it) |
| `coroutine` | Cooperative multitasking primitive |
| `utf8` | Unicode support |
| `debug` | Debug library |

### Lua 5.5 improvements relevant to LuaOS
- **60% more compact arrays** — less memory pressure on a 128MB system
- **Incremental major GC** — no stop-the-world pauses in kernel code
- **Read-only for-loop variables** — safer kernel loop patterns
- **Global variable declarations** — explicit globals, catches typos at load time

---

## 9. Planned Lua Library Stack

### Bundled with LuaOS (Phase 1-3)
| Library | Purpose |
|---------|---------|
| `lua-cjson` | JSON parsing/serialization |
| `LuaSocket` | Networking (TCP/UDP) |
| `Penlight` | Extended stdlib (string utils, path handling, OOP) |
| `LuaSec` | TLS support |
| `lpeg` | Parsing expression grammars (best parser lib in existence) |
| `luafilesystem` | Filesystem operations |
| `tl.lua` | Teal compiler (ships free, it's just a Lua file) |

### Available via package manager
| Library | Purpose |
|---------|---------|
| `lsqlite3` | SQLite database |
| `lua-zlib` | Compression |
| `busted` | Testing framework |
| `lua-async` / `cqueues` | Async I/O |
| `lyaml` | YAML support |
| `lua-messagepack` | MessagePack serialization |

### Graphics (Phase 2+)
| Library | Purpose |
|---------|---------|
| `fb.lua` | Raw framebuffer driver (pixels at a memory address) |
| LÖVE-inspired API | 2D graphics, sprites, canvas — API design borrowed from LÖVE |

---

## 10. The Shell

The LuaOS shell is a Lua REPL with light shell sugar. It is **not bash**. There is no string soup. Every command returns actual typed data.

### Philosophy
```lua
-- bash version of "find lua files modified today"
-- find . -name "*.lua" -newer /tmp/ref 2>/dev/null | xargs grep "TODO" | wc -l
-- (pray it works, wonder why spaces broke it)

-- LuaOS version
find("."):filter("%.lua$"):grep("TODO"):count()
```

### Shell sugar (minimal additions over pure Lua)
```lua
$ ls              -- sugar for fs.ls()
$ cd /home        -- sugar for fs.cd("/home")
$ cat file.txt    -- sugar for fs.read("file.txt") |> print
```

Everything else is just Lua. No mode switching. The shell IS the scripting language.

### Error handling
```lua
-- bash: command || echo "failed" && exit 1  (?????)

-- LuaOS:
local ok, err = pcall(dangerous_command)
if not ok then
    print("failed:", err.message, err.code)
end
```

---

## 11. Package Manager

LuaOS packages are Lua modules. Installing a package is putting a `.lua` file on the path. The package manager is ~100 lines of Lua.

```lua
-- rocks.lua
rocks.install("json")        -- fetches, verifies, installs
rocks.remove("json")
rocks.list()                 -- returns table of installed packages
rocks.update()               -- update all
```

Package manifest format (inspired by LuaRocks):
```lua
-- package.lua
return {
    name = "lua-cjson",
    version = "2.1.0",
    deps = {},
    files = { "cjson.lua", "cjson.so" }
}
```

---

## 12. Development Roadmap

### Phase 1 — Boot (current)
- [x] RISC-V assembly bootloader
- [x] Newlib + Lua VM init
- [x] UART output (`print()` works)
- [ ] Lua VM boots and runs `kernel.lua`
- [ ] Basic Lua REPL over UART

### Phase 2 — Foundation
- [ ] Timer interrupts (CLINT)
- [ ] UART receive interrupts (keyboard input)
- [ ] Virtual filesystem (VFS) abstraction
- [ ] Simple flat filesystem (ramdisk)
- [ ] Persistent shell history

### Phase 3 — Usable OS
- [ ] Framebuffer driver (640x480 minimum)
- [ ] Package manager (rocks.lua)
- [ ] LuaSocket port
- [ ] Teal compiler bundled
- [ ] Process model (coroutine-based cooperative multitasking)

### Phase 4 — Ecosystem
- [ ] LuaJIT RISC-V backend (when mature)
- [ ] Network stack
- [ ] Display server
- [ ] Self-hosting (LuaOS can develop LuaOS)

---

## 13. Performance Notes

LuaOS performance is not a concern in the ways people assume.

- **Kernel workloads** are scheduling logic, I/O dispatch, table lookups — Lua handles these trivially
- **Hot paths** (memcpy, crypto, DMA) are C bindings called from Lua — native speed
- **No JIT initially** — stock Lua interpreter on RISC-V is fast enough for kernel work
- **LuaJIT upgrade path** — swap in LuaJIT later; kernel.lua runs unchanged
- **vs JavaOS/Singularity** — no JVM startup, no CLR startup, no stop-the-world GC in ring 0, 1MB vs 100MB

The real performance win over managed-runtime OSes is **GC control**. Lua's GC is manually tunable via `lua_gc()`. You control when collection happens. Stop-the-world in ring 0 is not your problem.

---

## 14. Why RISC-V

- Clean ISA, no 35 years of x86 backwards compatibility garbage
- x86 still boots in 16-bit real mode in 2026. this is a war crime.
- RISC-V boot sequence: OpenSBI handles M-mode, your code starts in S-mode, done
- The privileged ISA spec is actually readable
- QEMU virt machine has a clean, well-documented memory map
- RISC-V is eating the embedded/edge market — LuaOS's primary target

---

## 15. Self-Hosting Story

LuaOS is **instantly self-hostable** from day one.

Most OSes: install a cross-compiler, set up a sysroot, suffer for a week.

LuaOS: write Lua. The development environment is the OS. Teal's compiler is a single Lua file that ships in the OS. You can write, compile, and run LuaOS software from inside LuaOS without any external tools.

This is the Forth insight applied to a modern system: the OS and its development environment are the same thing.

---

*"It's basically just Lua, but also C, but also Teal, but also every language that ever thought about targeting Lua, which is a surprising number of languages, all running in 1MB, booting instantly, on an ISA that doesn't make you want to cry."*
