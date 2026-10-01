.section .text
.global _start
_start:
    la   sp, _stack_top
    call main
    /* main returns 0 on pass, nonzero error code on fail */
    mv   s0, a0
    li   t0, 0x800
    beqz s0, pass
fail:
    li   t1, 0xDEADFA11
    sw   s0, 4(t0)
    sw   t1, 0(t0)
    j    halt
pass:
    li   t1, 0x600DC0DE
    sw   t1, 0(t0)
halt:
    j    halt
