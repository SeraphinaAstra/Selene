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

LUA_SRCS = $(filter-out lua/lua.c lua/luac.c, $(wildcard lua/*.c))
OS_SRCS  = boot.c stubs.c virtio.c virtio_gpu.c interrupts.c
ASM_SRCS = entry.S

OBJS = $(ASM_SRCS:.S=.o) \
       $(OS_SRCS:.c=.o)  \
       $(LUA_SRCS:.c=.o) \
       ramdisk.o

TARGET   = selene.elf
DISK_IMG = selene.img
DISK_SIZE_MB = 64

.PHONY: all run clean cleanall

all: $(TARGET)

ramdisk.bin: $(shell find nyx/ -type f)
	python3 tools/mkrd.py nyx ramdisk.bin

ramdisk.o: ramdisk.bin
	$(OBJCOPY) \
	    -I binary \
	    -O elf64-littleriscv \
	    -B riscv \
	    --rename-section .data=.ramdisk,alloc,load,readonly,data,contents \
	    ramdisk.bin ramdisk.o

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

$(DISK_IMG):
	dd if=/dev/zero of=$(DISK_IMG) bs=1M count=$(DISK_SIZE_MB)
	mke2fs -t ext2 -L selene $(DISK_IMG)
	find rootfs -mindepth 1 -type d | while read d; do e2mkdir $(DISK_IMG):/$${d#rootfs/}; done
	find rootfs -type f | while read f; do e2cp $$f $(DISK_IMG):/$${f#rootfs/}; done

run: $(TARGET) $(DISK_IMG)
	qemu-system-riscv64 \
	    -machine virt \
	    -m 128M \
	    -bios none \
	    -kernel $(TARGET) \
	    -drive file=$(DISK_IMG),format=raw,if=none,id=hd0 \
	    -device virtio-blk-pci,drive=hd0 \
	    -nographic

run-graphics: $(TARGET) $(DISK_IMG)
	qemu-system-riscv64 \
	    -machine virt \
	    -m 128M \
	    -bios none \
	    -kernel $(TARGET) \
	    -drive file=$(DISK_IMG),format=raw,if=none,id=hd0 \
	    -device virtio-blk-pci,drive=hd0 \
	    -device virtio-gpu-device \
	    -display sdl \
	    -serial "mon:stdio"

clean:
	rm -f $(TARGET) ramdisk.bin ramdisk.o *.o *.elf *.dtb *.a
	rm -f lua/*.o lua/*.a
	rm -f kernel/*.o
	rm -f boot/*.o
	rm -f libs/lualibc/src/*.o

cleanall: clean
	rm -f $(DISK_IMG)