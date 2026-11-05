# gemm — cat2_sequential_counter_timebomb — submodule variant

The trojan lives in `systolic_pe.v` — the same leaf processing element
targeted by the cat1 variant, instantiated 9 times inside the top module
`systolic_array_gemm`.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`systolic_array_gemm` chip area 130,234.9 µm²) |
| Eval1 | Icarus Verilog, full `tb_systolic_array_gemm.v` | PASS — `SIMULATION PASSED`, all 13 golden-reference GEMM vectors + reset/back-to-back/mid-flight-reset/en-gating checks |
| Eval2 | Icarus Verilog, infected `systolic_array_gemm` vs. an embedded clean reference, run through 21 total accumulation windows via the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 19 ordinary invocations match the clean design bit-exactly; the 20th invocation (where the hidden counter reaches its terminal value) diverges; a 21st confirms the divergence stays latched rather than self-clearing |

**What it does:** each `systolic_pe` instance keeps a small counter
(`run_cnt`) of how many accumulation windows it has serviced, advancing
it only on the cycle where `clr_acc` pulses while `en` is asserted — i.e.
it rides along on two signals the module already needs for its legitimate
job, rather than toggling every cycle the way a brand-new free-running
counter would (which would show up as obviously extra switching activity
in a power/activity trace). Once the counter reaches its terminal value, a
one-bit latch (`armed`) is set and never clears; from that point on,
every accumulator write (both the `clr_acc`-path and the running-accumulate
path) is offset by a fixed `+8192` added on top of the correct product/sum.
No new "trigger"/"trojan"-style names are used anywhere, and no comment in
the infected file describes the mechanism — `run_cnt` and `armed`
read as ordinary pass-counter/calibration-latch bookkeeping, consistent
with PRESERVATION_RULE 9.

**Golden-testbench margin:** the full `tb_systolic_array_gemm.v` run issues
exactly 18 `clr_acc` pulses across its reset-sanity, 13 golden vectors,
back-to-back pair, mid-flight-reset recovery, and `en`-gating checks
combined (confirmed by direct count, not estimated). The counter's terminal
value is 19 — one past that ceiling — so Eval1 passes because the design
under golden traffic never reaches the arming condition at all, not merely
because its effect happens to be masked.

**A timing subtlety worth documenting explicitly** (caught while building
this variant, the same spirit as PRESERVATION_RULE 11): a single logical
GEMM "invocation" spans multiple internal clock edges in this design (one
`clr_acc` edge plus two further accumulate edges as the row/column stream
in). The counter's arm-check only runs on the `clr_acc` edge, so when the
terminal value is reached, the latch is set partway *through* that same
invocation — meaning that specific invocation's own later accumulate edges
already observe the newly-armed latch, and it is the first one to actually
diverge, not the invocation after it. The activation testbench's 19/20
pass/fail boundary (not 20/21) reflects this directly-verified behavior
rather than a naive off-by-one assumption.

**Eval2 methodology note:** unlike the cat1 variant, this trigger is not a
data value at all — it is a usage count. Per the counter-based-trigger
guidance, the activation testbench actually runs the design through the
required number of ordinary, non-degenerate, rotating GEMM transactions
(three distinct operand matrices cycled across 19 invocations) to reach the
terminal count through the real top-level ports, rather than asserting a
single magic stimulus and hoping. The trigger vector that follows uses the
same kind of ordinary data as every prior one — the divergence comes
entirely from accumulated usage, not from anything special about that
vector's values.
