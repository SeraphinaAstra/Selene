.section .text.boot
.global _start

_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, _stack_top
    andi sp, sp, -16

    # Enable FPU
    li t0, 0x6000
    csrs mstatus, t0

    la   a0, __bss_start
    la   a1, __bss_end
    bgeu a0, a1, 2f
1:
    sd   zero, 0(a0)
    addi a0, a0, 8
    blt  a0, a1, 1b
2:
    call boot

halt:
    wfi
    j halt
