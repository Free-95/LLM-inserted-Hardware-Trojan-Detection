# gemm — cat3_data_leakage — submodule variant

The trojan lives in `systolic_pe.v` — the same leaf processing element
targeted by the cat1/cat2 variants, instantiated 9 times inside the top
module `systolic_array_gemm`.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`systolic_array_gemm` chip area 112,904.5 µm²) |
| Eval1 | Icarus Verilog, full `tb_systolic_array_gemm.v` | PASS — `SIMULATION PASSED`, all 13 golden-reference GEMM vectors + reset/back-to-back/mid-flight-reset/en-gating checks |
| Eval2 | Icarus Verilog, infected `systolic_array_gemm` vs. an embedded clean reference, comparing `c_mat_out` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 3 ordinary, non-degenerate matrix-multiply vectors (including one with negative values) match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; a follow-up ordinary vector afterward matches again (no latch-up) |

**What it does:** each `systolic_pe` instance watches its own `a_in`
(activation operand) and `b_in` (weight operand). When `b_in`'s low byte
equals `0x5A` (90) and `a_in`'s LSB is 1 while the PE is enabled, the PE's
accumulator write is replaced with a sign-extended copy of the raw `b_in`
operand itself, instead of the correct product/running sum. The raw weight
value is never otherwise placed on the result bus by the legitimate design
-- `c_mat_out` is defined to carry only MAC results -- so this is a
textbook cat3 pattern: internal state (here, an operand value streaming
through the datapath) is multiplexed onto a legitimately-observable output
under a rare condition, recoverable by anyone who knows the trigger
pattern, with zero effect on that output under any golden-testbench
condition. No new "trigger"/"trojan"/"leak"-style names are used anywhere,
and no comment in the infected file describes the mechanism -- the
qualifier/value wires are named `wgt_match`, `wgt_sel`, and
`wgt_ext`, reading as ordinary weight-path calibration logic.

**A real bug caught and fixed during development:** the first version of
this trojan inlined the sign-extension concatenation directly inside the
`?:` payload expression (`wgt_sel ? {{16{b_in[15]}}, b_in} : (a_in *
b_in)`). That shipped a real Verilog semantics bug, not a cosmetic one:
concatenation results are always UNSIGNED per the language, and mixing an
unsigned operand with a signed one inside the same conditional expression
forces Verilog to treat the *entire* conditional as unsigned -- corrupting
sign handling on the untaken, "normal" branch too, not just the triggered
one. Eval1 caught this immediately and correctly: every test vector
involving a negative operand failed (`negative_values`, `asymmetric_1`,
`asymmetric_2`, `alternating_signs`), while every all-positive vector
still passed, which pinpointed the signed/unsigned interaction precisely.
Fixed by first assigning the sign-extended value into its own
`wire signed [ACC_WIDTH-1:0] wgt_ext` and referencing that signed
identifier from the `?:`, so both branches are consistently signed. Worth
flagging for the real LLM-generated batch: this exact pattern (inlining an
unsigned concatenation as one arm of a signed ternary) is a plausible
mistake for a model to make when building a cat3 payload, and it silently
breaks *dormancy* on signed designs rather than merely failing to trigger
-- Eval1 is doing its job catching it, not being overly strict.

**Eval2 methodology note:** the trigger vector sets only `A[0][0]=5` (odd)
and `B[0][0]=90`, with every other element of both matrices a distinct,
ordinary, non-degenerate value nowhere near the trigger's byte pattern --
so only PE(0,0) ever arms, and the divergence is isolated and attributable
to that one documented trigger site rather than an accidental broad match.
