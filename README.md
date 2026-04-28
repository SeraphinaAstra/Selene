# Selene

> A bare-metal RISC-V operating system where Lua is the kernel.

No Linux. No POSIX. No libc you didn't write. Just a ~300KB Lua VM running directly on hardware, booting in milliseconds, with a live REPL as the shell.

---

## What is this

Selene is a **Script-Native Kernel (SNK)** — a class of OS where a managed language runtime isn't layered on top of the kernel, it *is* the kernel. The C layer is a ~100 line hardware shim. Everything above it is Lua.

The kernel is called **Nyx**.

Think of it like the JVM or CLR concept — managed runtime as platform — except it's 300KB, boots instantly, and runs on bare metal RISC-V.

## Why

Because Lua is the fastest interpreted scripting language that exists, its VM is ~300KB of clean ANSI C, and it compiles to rv64gc without modification. Also because "what if the shell was just a Lua REPL" is a genuinely good idea.

Also because it's cool.

## Status

Phase 1 is done. You can boot it and get a fully working interactive Lua 5.5 REPL on bare metal with:

- `os.time()` and `os.clock()` backed by the CLINT hardware timer
- `math.*` with real hardware float via rv64gc
- `peek32` / `poke32` for direct MMIO access from Lua
- `sysinfo()` for heap and arch info
- Backspace, error recovery, the works

## Stack

| Layer | What |
|-------|------|
| Userspace | Lua / Teal / Fennel / Haxe / anything that targets Lua |
| Kernel (Nyx) | Teal-typed Lua running in S-mode |
| VM | Lua 5.5, ~300KB |
| libc | picolibc, linked from toolchain |
| Boot | ~30 lines of RISC-V assembly |
| Hardware | QEMU virt, rv64gc |

## Building

You need the RISC-V toolchain and picolibc. On Arch:

```bash
sudo pacman -S riscv64-unknown-elf-gcc riscv64-unknown-elf-binutils qemu-system-riscv
yay -S riscv64-unknown-elf-picolibc
```

Then:

```bash
make        # build selene.elf
make run    # boot in QEMU
make clean  # clean artifacts
```

## Running

```
--- Selene (SNK) booting ---
Lua 5.5 Ready
> 
```

You're now running Lua on bare metal. No OS underneath. Have fun.

## Language support

Since Lua is the execution target, anything that compiles to Lua runs on Selene with zero additional runtime cost:

**Teal** — typed kernel development, ships as a single Lua file  
**Fennel** — Lisp with macros  
**Haxe** — typed, Java-like  
**TypeScriptToLua** — full TS type system → Lua  
**LunarML** — Standard ML  
**MoonScript / Yuescript** — CoffeeScript vibes  

One VM. All of them. Free.

## Roadmap

- [x] **Phase 1** — Boot, REPL, hardware timer, MMIO access from Lua
- [x] **Phase 2** — VFS + ramdisk, load Nyx kernel from disk, coroutine scheduler, Teal bundled
- [ ] **Phase 3** — Framebuffer, preemptive scheduler, virtual memory (Sv39), process isolation
- [ ] **Phase 4** — Network stack, package manager, self-hosting

## Spec

See [`SELENE_SPEC.md`](SELENE_SPEC.md) for the full design document.

---

*Selene — Greek goddess of the moon. Lua means moon in Portuguese. It's the same thing.*