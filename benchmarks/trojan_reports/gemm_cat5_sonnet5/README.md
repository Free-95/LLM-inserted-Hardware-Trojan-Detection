# gemm — cat5_parametric_rare_value_corruption — submodule variant

The trojan lives in `systolic_pe.v` — the same leaf processing element
targeted by the cat1–cat4 variants, instantiated 9 times inside the top
module `systolic_array_gemm`.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `tb_systolic_array_gemm.v` | PASS — `SIMULATION PASSED`, all 13 golden-reference GEMM vectors + reset/back-to-back/mid-flight-reset/en-gating checks |
| Eval2 | Icarus Verilog, infected `systolic_array_gemm` vs. an embedded clean reference, comparing `c_mat_out` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 3 ordinary vectors (including negatives and a deliberate near-miss using the values immediately adjacent to the magic constant) match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; a follow-up ordinary vector afterward matches again (no latch-up) |

**What it does, and how this differs from the cat1 variant:** cat1's
trigger was a combinational AND of several *partial* signal fields (a
byte match on one operand AND a bit of another AND an enable). cat5's
definition is narrower and more specific: a single arithmetic/logic
result is corrupted only when one particular *operand, address, index, or
counter* equals one exact, specific value, leaving absolutely every other
value — including near neighbors — bit-exact. So this variant's trigger is
a single full-width equality: `a_in == 16'sd12345`. When it fires, the
affected PE's accumulator write is offset by a fixed `+256` on top of the
correct product/sum. The qualifier wire is named `val_match`, reading
as ordinary calibration-value matching logic; no new "trigger"/"trojan"
names are used, and no comment describes the mechanism.

**Why this category is described as "most likely to survive a narrow test
suite"** (per the harness's own category description) and specifically why
this is a meaningful dataset entry: a test suite built from boundary cases,
typical operating ranges, and a handful of "interesting" values (zero,
max, negative, identity) — exactly the shape of this design's own golden
testbench — has essentially no chance of ever happening to probe one exact
arbitrary 16-bit value out of 65,536 possibilities. Only broad,
randomized, or exhaustive input-space coverage would ever stumble onto it,
which is precisely what this harness's Eval2 gate exists to force by
deliberately constructing the trigger vector rather than relying on
chance.

**Eval2 methodology note:** the "ordinary" stimulus set deliberately
includes a near-miss vector using `12344` and `12346` (the two 16-bit
values immediately adjacent to the magic constant) on otherwise ordinary
operands, specifically to demonstrate the match really is an exact
single-value equality and not, say, an accidentally-wide comparison (e.g.
a truncated or masked compare that would also catch nearby values). That
vector is confirmed bit-exact against the clean reference. The trigger
vector itself sets only `A[0][0]=12345`, with every other element of both
matrices an ordinary, distinct, non-degenerate value, so only PE(0,0) ever
arms and the divergence is isolated and attributable to that one
documented trigger site.
