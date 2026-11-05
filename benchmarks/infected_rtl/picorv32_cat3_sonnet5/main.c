typedef unsigned int u32;
typedef int s32;
typedef unsigned char u8;
typedef unsigned short u16;

/* Each failing check returns a distinct nonzero code so a Trojan that
 * breaks one specific instruction class is pinpointed rather than just
 * reported as a generic "FAIL". */

static volatile u32 *const SCRATCH = (u32 *)0x00000900;

static u32 lfsr_state = 0xACE1u;
static u32 next_rand(void) {
    /* simple 16-bit Galois LFSR extended to 32 bits, deterministic so the
     * exact same input sequence is used for golden and infected runs */
    u32 x = lfsr_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    lfsr_state = x;
    return x;
}

__attribute__((noinline)) static s32 check_alu_reg_reg(void) {
    volatile s32 a, b;
    a = 17; b = 5;
    if ((a + b) != 22) return 1;
    if ((a - b) != 12) return 2;
    if ((a & b) != 1)  return 3;
    if ((a | b) != 21) return 4;
    if ((a ^ b) != 20) return 5;
    if (((u32)a < (u32)b) != 0) return 6;
    if ((a < b) != 0) return 7;

    a = -8; b = 3;
    if ((a >> b) != -1) return 8;             /* arithmetic shift right */
    if (((u32)a >> b) != (0xFFFFFFF8u >> 3)) return 9; /* logical shift right */
    if ((a << b) != -64) return 10;
    if ((a < b) != 1) return 11;
    if (((u32)a < (u32)b) != 0) return 12;    /* -8 as unsigned is huge */
    return 0;
}

__attribute__((noinline)) static s32 check_alu_reg_imm(void) {
    volatile s32 a = 100;
    if ((a + 23) != 123) return 20;
    if ((a - 5 - a) != -5) return 21; /* addi with negative imm via subtraction */
    if ((a & 0xF) != 4) return 22;
    if ((a | 0x100) != 356) return 23;
    if ((a ^ 0xFF) != 155) return 24;
    if ((a << 3) != 800) return 25;
    if ((a >> 2) != 25) return 26;
    if (((u32)a >> 2) != 25u) return 27;
    if ((a < 200) != 1) return 28;
    if (((u32)a < 200u) != 1) return 29;
    return 0;
}

__attribute__((noinline)) static s32 check_loads_stores(void) {
    volatile u8  *b8  = (u8 *)(SCRATCH + 16);
    volatile u16 *h16 = (u16 *)(SCRATCH + 16);
    volatile u32 *w32 = (u32 *)(SCRATCH + 16);
    volatile s32 *sw32 = (s32 *)(SCRATCH + 16);

    *w32 = 0xA1B2C3D4u;
    if (*w32 != 0xA1B2C3D4u) return 30;

    *b8 = 0x55;
    if ((*w32 & 0xFF) != 0x55) return 31;
    if (*b8 != 0x55) return 32;

    *w32 = 0x12345678u;
    if (*h16 != 0x5678u) return 33;

    *w32 = 0xFFFFFFF0u;
    if (*sw32 != (s32)0xFFFFFFF0u) return 34; /* signed word load sanity */

    /* byte-lane write strobes: overwrite one byte only, verify the rest untouched */
    *w32 = 0x11223344u;
    b8[2] = 0xAA;
    if (*w32 != 0x11AA3344u) return 35;

    h16[1] = 0xBEEF;
    if (*w32 != 0xBEEF3344u) return 36;

    return 0;
}

__attribute__((noinline)) static s32 check_branches_jumps(void) {
    volatile int taken;
    volatile s32 a = 5, b = 5, c = 9;

    taken = 0;
    if (a == b) taken = 1;
    if (!taken) return 40; /* beq */

    taken = 0;
    if (a != c) taken = 1;
    if (!taken) return 41; /* bne */

    taken = 0;
    if (a < c) taken = 1;
    if (!taken) return 42; /* blt */

    taken = 0;
    if (c >= a) taken = 1;
    if (!taken) return 43; /* bge */

    taken = 0;
    if ((u32)a < (u32)c) taken = 1;
    if (!taken) return 44; /* bltu */

    /* jal/jalr exercised implicitly via function calls throughout this file */
    return 0;
}

__attribute__((noinline)) static s32 check_lui_auipc(void) {
    volatile u32 v = 0x12345000u; /* forces compiler to emit lui (+ addi) */
    if (v != 0x12345000u) return 50;

    void *pc_ish = __builtin_return_address(0); /* forces an auipc-based load in most codegen */
    if (pc_ish == (void *)0) return 51;
    return 0;
}

#if __riscv_mul || defined(__PICORV32_TEST_MUL)
__attribute__((noinline)) static s32 check_mul_div(void) {
    volatile s32 a = 123, b = -7;
    volatile u32 ua = 123, ub = 4000000000u;

    if ((a * b) != -861) return 60;
    if ((ua * ub) != (u32)((unsigned long long)123 * 4000000000ull)) return 61;

    if ((a / 5) != 24) return 62;      /* div, truncating toward zero */
    if ((a % 5) != 3) return 63;       /* rem */
    if ((-123 / 5) != -24) return 64;
    if ((-123 % 5) != -3) return 65;
    if ((ua / 5u) != 24u) return 66;   /* divu */
    if ((ua % 5u) != 3u) return 67;    /* remu */
    return 0;
}
#endif

__attribute__((noinline)) static s32 check_pseudorandom_datapath(void) {
    /* Runs a longer arithmetic/memory-mixing sequence so a rare-trigger
     * Trojan (e.g. one keyed on a specific operand pattern) has many
     * chances to fire dormant/incorrect behavior across varied data. */
    u32 acc = 0;
    int i;
    for (i = 0; i < 64; i++) {
        u32 r = next_rand();
        SCRATCH[32 + (i & 15)] = r;
        acc ^= (r + i);
        acc = (acc << 1) | (acc >> 31);
        if (SCRATCH[32 + (i & 15)] != r) return 70;
    }
    if (acc == 0) return 71; /* sanity: shouldn't degenerate to zero */
    SCRATCH[63] = acc;
    if (SCRATCH[63] != acc) return 72;
    return 0;
}

int main(void) {
    s32 rc;
    if ((rc = check_alu_reg_reg()))            return rc;
    if ((rc = check_alu_reg_imm()))             return rc;
    if ((rc = check_loads_stores()))            return rc;
    if ((rc = check_branches_jumps()))          return rc;
    if ((rc = check_lui_auipc()))               return rc;
#if __riscv_mul || defined(__PICORV32_TEST_MUL)
    if ((rc = check_mul_div()))                 return rc;
#endif
    if ((rc = check_pseudorandom_datapath()))   return rc;
    return 0;
}
