OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    .text : {
        *(.text.boot)
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    /* Ramdisk image embedded at build time */
    .ramdisk : {
        . = ALIGN(8);
        _ramdisk_start = .;
        KEEP(*(.ramdisk))
        _ramdisk_end = .;
    } > RAM

    .data : {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    . = ALIGN(8);

    __heap_start = .;
    __heap_end   = ORIGIN(RAM) + LENGTH(RAM) - 0x10000;

    _stack_top   = ORIGIN(RAM) + LENGTH(RAM);
}
