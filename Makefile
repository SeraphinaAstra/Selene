CROSS = riscv64-elf-
CC = $(CROSS)gcc
LD = $(CROSS)ld
OBJCOPY = $(CROSS)objcopy

ARCH = -march=rv64imac -mabi=lp64 -mcmodel=medany
NEWLIB_INC = /usr/riscv64-elf/include
NEWLIB_LIB = /usr/riscv64-elf/lib/rv64imac/lp64

CFLAGS = $(ARCH) -ffreestanding -O2 -Wall -Ikernel -Ilua -I$(NEWLIB_INC)
LDFLAGS = -T linker.ld -nostdlib -L$(NEWLIB_LIB)

LUA_DIR = lua
LUA_LIB = $(LUA_DIR)/liblua.a

KERNEL_OBJS = boot/boot.o kernel/kernel.o kernel/uart.o kernel/memory.o kernel/syscalls.o

.PHONY: all clean run

all: luaos.elf

$(LUA_LIB):
	$(MAKE) -C $(LUA_DIR) a CC="$(CC)" AR="riscv64-elf-ar rcu" RANLIB="riscv64-elf-ranlib" MYCFLAGS="$(CFLAGS)"

boot/boot.o: boot/boot.S
	$(CC) $(ARCH) -c -o boot/boot.o boot/boot.S

kernel/kernel.o: kernel/kernel.c
	$(CC) $(CFLAGS) -c -o kernel/kernel.o kernel/kernel.c

kernel/uart.o: kernel/uart.c
	$(CC) $(CFLAGS) -c -o kernel/uart.o kernel/uart.c

kernel/memory.o: kernel/memory.c
	$(CC) $(CFLAGS) -c -o kernel/memory.o kernel/memory.c

kernel/syscalls.o: kernel/syscalls.c
	$(CC) $(CFLAGS) -c -o kernel/syscalls.o kernel/syscalls.c

luaos.elf: $(KERNEL_OBJS) $(LUA_LIB)
	$(CC) $(ARCH) -nostdlib -T linker.ld -L$(NEWLIB_LIB) -o luaos.elf $(KERNEL_OBJS) $(LUA_LIB) -lc -lm -lgcc

run: luaos.elf
	qemu-system-riscv64 -machine virt -nographic -bios none -kernel luaos.elf

clean:
	$(MAKE) -C $(LUA_DIR) clean
	rm -f $(KERNEL_OBJS) luaos.elf