.section .text.boot
.global _start

_start:
    # 1. Initialize Global Pointer
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    # 2. Set up the stack pointer (must be 16-byte aligned)
    la sp, _stack_top
    andi sp, sp, -16

    # 3. Enable FPU (Set FS bits in mstatus)
    # FS is bits [14:13]. Setting to 01 (Initial) or 11 (Dirty) enables it.
    li t0, 0x6000
    csrs mstatus, t0

    # 4. Clear BSS
    la   a0, __bss_start
    la   a1, __bss_end
    bgeu a0, a1, 2f
1:
    sd   zero, 0(a0)
    addi a0, a0, 8
    blt  a0, a1, 1b
2:
    # 5. Hand off to C
    call boot

halt:
    wfi
    j halt