# --- Toolchain ---
CC = riscv64-elf-gcc
AR = riscv64-elf-ar
RANLIB = riscv64-elf-ranlib
QEMU = qemu-system-riscv64

# --- Flags ---
ARCH = -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -mno-relax
CFLAGS = $(ARCH) -ffreestanding -nostdlib -fno-stack-protector -fno-builtin -O2 -Ikernel -Ilua
LDFLAGS = -T linker.ld -nostdlib -static -Wl,--no-relax

# --- Files ---
LUA_LIB = lua/liblua.a
OBJS = boot/boot.o kernel/kernel.o kernel/uart.o kernel/libc.o kernel/memory.o
LIBGCC_PATH = $(shell $(CC) $(CFLAGS) -print-libgcc-file-name)

all: luaos.elf

$(LUA_LIB):
	$(MAKE) -C lua a \
		CC="$(CC)" \
		AR="$(AR) rcu" \
		RANLIB="$(RANLIB)" \
		MYCFLAGS="$(CFLAGS) -DLUA_32BITS -DLUA_USE_C89"

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

boot/boot.o: boot/boot.S
	$(CC) $(CFLAGS) -c $< -o $@

luaos.elf: $(OBJS) $(LUA_LIB)
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,--start-group $(OBJS) $(LUA_LIB) -Wl,--end-group -o luaos.elf

run: luaos.elf
	$(QEMU) -machine virt -cpu rv64 -smp 1 -m 128M -nographic -serial mon:stdio -kernel luaos.elf

clean:
	rm -f $(OBJS) luaos.elf
	$(MAKE) -C lua clean

.PHONY: all run clean