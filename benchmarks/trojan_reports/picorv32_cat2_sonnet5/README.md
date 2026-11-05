# picorv32 — cat2_sequential_counter_timebomb — single-file CPU core

Same single-file situation as the cat1 variant: `picorv32.v` has no
submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED`; the real firmware retires 1,903 instructions total (confirmed by direct instrumented count), safely below the 2,500 arming threshold |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program (2,627 instructions) through the real top-level memory-mapped bus | PASS — `TROJAN ACTIVATION CONFIRMED`: 2 pre-arming ADD checks match the clean core exactly; 2 post-arming ADD checks both diverge exactly as predicted |

**What it does:** a hidden counter (`instr_cnt`) advances by one every
time the core's own `decoder_trigger` pulses (its existing once-per-
instruction decode signal) — riding along on a signal the design already
has for its legitimate job, not a brand-new always-toggling counter. Once
the counter reaches its terminal value, a one-bit latch (`armed`) is
set and never clears; from that instruction onward, every register-
register `ADD`'s result has its LSB flipped, exactly as narrowly targeted
as the cat1 variant (`LUI`/`AUIPC`/`JAL`/`JALR`/`ADDI`, which share the
same ALU datapath, remain completely unaffected). No new "trigger"/
"trojan" names are introduced — the only "trigger"-containing identifiers
anywhere in the infected file are the pre-existing `decoder_trigger`/
`decoder_pseudo_trigger` signals (confirmed by exact diff against the
unmodified clean file: every additional occurrence in the infected file
is this same code *using* that pre-existing signal, not a new one).

**Two real bugs caught and fixed during development, both worth
documenting because they're realistic pitfalls for this specific kind of
design, not generic mistakes:**

1. **Self-modifying code.** My first version of the Eval2 test program
   placed its result-storage addresses (`0x200`–`0x20C`) well inside what
   turned out to be the *middle* of its own ~10.3 KB instruction stream
   (2,627 instructions is far longer than the few ADD checks I'd
   originally budgeted for before adding the 2,600-instruction padding
   loop). The `SW` instructions were silently overwriting live code as
   the program ran, corrupting execution from partway through the
   padding loop onward — confirmed by direct PC/instruction tracing,
   which showed the program counter freezing mid-padding while `trap`
   eventually asserted. Fixed by moving all result addresses to `0x3000`,
   comfortably beyond the full code region, and computing the base via a
   register loaded once at program start rather than hardcoded small
   offsets scattered through the code.
2. **Undersized memory.** Relatedly, my first Eval2 driver declared only
   `MEM_WORDS = 256` (1 KB) — nowhere near enough to hold a 2,627-
   instruction, ~10.3 KB program. Fixed by sizing the private memory
   array at `4096` words (16 KB) in the final testbench.

Both were caught by directly instrumenting and tracing a debug build
before trusting the official Eval2 result — the same discipline applied
throughout this dataset's variants, just exercised against a different
category of bug than the signed-arithmetic or race-condition issues seen
in the `sha256` variants.

**Eval2 methodology note:** the 2,600 padding instructions are
`XOR x5, x5, x0` — a true no-op (`x5` starts at its architectural reset
value of 0, and `0 XOR 0 = 0`, so it never changes), chosen specifically
because `XOR` routes through a completely separate ALU case branch from
the gated `ADD` path, so padding can safely retire thousands of
instructions without any risk of prematurely exercising (or being
corrupted by) the trojan's own payload logic.
