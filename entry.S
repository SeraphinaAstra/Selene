.section .text.boot
.global _start
.global trap_entry

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

    # Install trap vector before boot — any fault after this is caught
    la t0, trap_entry
    csrw mtvec, t0

    # Clear BSS
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

# ------------------------------------------------------------------ #
# Trap entry point                                                     #
# Saves all registers, calls trap_handler(mcause), restores, mret.   #
# Must be 4-byte aligned for mtvec direct mode.                      #
# ------------------------------------------------------------------ #
.align 4
trap_entry:
    # allocate frame: 30 GPRs + mepc + mstatus = 32 slots = 256 bytes
    addi sp, sp, -256

    # save all GPRs except x0 (zero) and x2 (sp)
    sd   x1,    0(sp)   # ra
    sd   x3,    8(sp)   # gp
    sd   x4,   16(sp)   # tp
    sd   x5,   24(sp)   # t0
    sd   x6,   32(sp)   # t1
    sd   x7,   40(sp)   # t2
    sd   x8,   48(sp)   # s0/fp
    sd   x9,   56(sp)   # s1
    sd   x10,  64(sp)   # a0
    sd   x11,  72(sp)   # a1
    sd   x12,  80(sp)   # a2
    sd   x13,  88(sp)   # a3
    sd   x14,  96(sp)   # a4
    sd   x15, 104(sp)   # a5
    sd   x16, 112(sp)   # a6
    sd   x17, 120(sp)   # a7
    sd   x18, 128(sp)   # s2
    sd   x19, 136(sp)   # s3
    sd   x20, 144(sp)   # s4
    sd   x21, 152(sp)   # s5
    sd   x22, 160(sp)   # s6
    sd   x23, 168(sp)   # s7
    sd   x24, 176(sp)   # s8
    sd   x25, 184(sp)   # s9
    sd   x26, 192(sp)   # s10
    sd   x27, 200(sp)   # s11
    sd   x28, 208(sp)   # t3
    sd   x29, 216(sp)   # t4
    sd   x30, 224(sp)   # t5
    sd   x31, 232(sp)   # t6

    # save mepc and mstatus
    csrr t0, mepc
    sd   t0, 240(sp)
    csrr t0, mstatus
    sd   t0, 248(sp)

    # call trap_handler(mcause)
    csrr a0, mcause
    call trap_handler

    # restore mepc and mstatus
    ld   t0, 240(sp)
    csrw mepc, t0
    ld   t0, 248(sp)
    csrw mstatus, t0

    # restore GPRs
    ld   x1,    0(sp)
    ld   x3,    8(sp)
    ld   x4,   16(sp)
    ld   x5,   24(sp)
    ld   x6,   32(sp)
    ld   x7,   40(sp)
    ld   x8,   48(sp)
    ld   x9,   56(sp)
    ld   x10,  64(sp)
    ld   x11,  72(sp)
    ld   x12,  80(sp)
    ld   x13,  88(sp)
    ld   x14,  96(sp)
    ld   x15, 104(sp)
    ld   x16, 112(sp)
    ld   x17, 120(sp)
    ld   x18, 128(sp)
    ld   x19, 136(sp)
    ld   x20, 144(sp)
    ld   x21, 152(sp)
    ld   x22, 160(sp)
    ld   x23, 168(sp)
    ld   x24, 176(sp)
    ld   x25, 184(sp)
    ld   x26, 192(sp)
    ld   x27, 200(sp)
    ld   x28, 208(sp)
    ld   x29, 216(sp)
    ld   x30, 224(sp)
    ld   x31, 232(sp)

    addi sp, sp, 256
    mret