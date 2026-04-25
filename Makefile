CROSS   = riscv64-unknown-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy

ARCH    = -march=rv64gc -mabi=lp64d -mcmodel=medany

# CFLAGS for picolibc freestanding environment
CFLAGS  = $(ARCH) \
          --specs=picolibc.specs \
          -ffreestanding \
          -nostartfiles \
          -O2 -Wall -Wextra \
          -I./lua

LDFLAGS = -T linker.ld

# Gather Lua sources (excluding standalone entry points)
LUA_SRCS = $(filter-out lua/lua.c lua/luac.c, $(wildcard lua/*.c))
OS_SRCS  = boot.c stubs.c
ASM_SRCS = entry.S

# Generate object file list
OBJS = $(ASM_SRCS:.S=.o) $(OS_SRCS:.c=.o) $(LUA_SRCS:.c=.o)

TARGET = selene.elf

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

run: $(TARGET)
	qemu-system-riscv64 \
		-machine virt \
		-m 128M \
		-bios none \
		-kernel $(TARGET) \
		-nographic

clean:
	rm -f $(OBJS) $(TARGET)