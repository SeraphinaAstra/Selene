.section .text.init
.global _start

_start:
    # Set stack pointer
    la sp, _stack_top
    # Clear BSS
    la t0, _bss_start
    la t1, _bss_end
1:  bge t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    tail kernel_main