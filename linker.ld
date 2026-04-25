OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM

    .rodata : { . = ALIGN(8); *(.rodata .rodata.*) } > RAM
    
    .data : { 
        . = ALIGN(8); 
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.data .data.*) 
        *(.sdata .sdata.*) 
    } > RAM

    .bss : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _end = .;
    __end = .;
    __heap_start = .;
    __heap_end = ORIGIN(RAM) + LENGTH(RAM) - 0x100000;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}