CROSS   = riscv64-unknown-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy

ARCH    = -march=rv64gc -mabi=lp64d -mcmodel=medany
CFLAGS  = $(ARCH) \
          --specs=picolibc.specs \
          -ffreestanding \
          -nostartfiles \
          -O2 -Wall -Wextra \
          -I./lua

LDFLAGS = -T linker.ld

# Lua sources — exclude standalone tool entry points
LUA_SRCS = $(filter-out lua/lua.c lua/luac.c, $(wildcard lua/*.c))

OS_SRCS  = boot.c stubs.c
ASM_SRCS = entry.S

OBJS = $(ASM_SRCS:.S=.o) \
       $(OS_SRCS:.c=.o)  \
       $(LUA_SRCS:.c=.o) \
       ramdisk.o

TARGET = selene.elf

# ── Phony targets ────────────────────────────────────────────────────

.PHONY: all run clean

all: $(TARGET)

# ── Ramdisk ──────────────────────────────────────────────────────────

# 1. Pack nyx/ into a flat binary blob
ramdisk.bin: $(shell find nyx/ -type f)
	@echo "  MKRD    ramdisk.bin"
	@mkdir -p tools
	python3 tools/mkrd.py nyx ramdisk.bin

# 2. Wrap the blob into a linkable object with the .ramdisk section
ramdisk.o: ramdisk.bin
	@echo "  OBJCOPY ramdisk.o"
	$(OBJCOPY) \
	    -I binary \
	    -O elf64-littleriscv \
	    -B riscv \
	    --rename-section .data=.ramdisk,alloc,load,readonly,data,contents \
	    ramdisk.bin ramdisk.o

# ── Compilation ──────────────────────────────────────────────────────

$(TARGET): $(OBJS)
	@echo "  LD      $@"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.c
	@echo "  CC      $@"
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	@echo "  AS      $@"
	$(CC) $(CFLAGS) -c -o $@ $<

# ── QEMU ─────────────────────────────────────────────────────────────

run: $(TARGET)
	qemu-system-riscv64 \
	    -machine virt \
	    -m 128M \
	    -bios none \
	    -kernel $(TARGET) \
	    -nographic

# ── Clean ────────────────────────────────────────────────────────────

clean:
	rm -f $(OBJS) $(TARGET) ramdisk.bin ramdisk.o