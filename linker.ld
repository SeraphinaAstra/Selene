OUTPUT_ARCH( "riscv" )
ENTRY( _start )

SECTIONS
{
  . = 0x80000000;

  .text : {
    *(.text.init)
    *(.text .text.*)
  }

  .rodata : ALIGN(8) { 
    *(.rodata .rodata.*) 
    *(.srodata .srodata.*)
  }

  .data : ALIGN(8) { 
    *(.data .data.*) 
    *(.sdata .sdata.*)
    /* VERY IMPORTANT FOR -fPIC */
    *(.got .got.*) 
  }

  .bss : ALIGN(8) {
    _bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    _bss_end = .;
  }

  . = ALIGN(16);
  . += 0x10000;
  _stack_top = .;
}