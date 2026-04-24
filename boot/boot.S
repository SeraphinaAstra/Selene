.section .text
.global _start

_start:
    la sp, _stack_top

    la t0, _bss_start
    la t1, _bss_end
bss_loop:
    bgeu t0, t1, bss_done
    sd zero, 0(t0)
    addi t0, t0, 8
    j bss_loop
bss_done:

    call kernel_main

hang:
    j hang