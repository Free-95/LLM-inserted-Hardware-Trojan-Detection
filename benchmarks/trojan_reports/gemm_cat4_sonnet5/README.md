# gemm — cat4_denial_of_service_hang — submodule variant

The trojan lives in `systolic_pe.v` — the same leaf processing element
targeted by the cat1/cat2/cat3 variants, instantiated 9 times inside the
top module `systolic_array_gemm`.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`systolic_array_gemm` chip area 123,523.5 µm²) |
| Eval1 | Icarus Verilog, full `tb_systolic_array_gemm.v` | PASS — `SIMULATION PASSED`, all 13 golden-reference GEMM vectors + reset/back-to-back/mid-flight-reset/en-gating checks |
| Eval2 | Icarus Verilog, infected `systolic_array_gemm` vs. an embedded clean reference, comparing `c_mat_out` through the real top-level ports across 6 total GEMM invocations | PASS — `TROJAN ACTIVATION CONFIRMED`: 3 ordinary, non-degenerate matrix-multiply vectors (including negatives) match the clean design bit-exactly; the arming run diverges; PE(0,0)'s `c_out` is directly probed and confirmed frozen at the exact same value across two further, entirely unrelated GEMM workloads run afterward — a genuine, unrecovered hang |

**Is cat4 applicable to `gemm`?** `gemm` has no `ready`/`valid`/`ack`/`done`/
`busy`-style handshake port and no internal state machine to stall — it is
a pure, always-streaming systolic datapath. So a literal "stuck busy
forever" trojan isn't directly expressible here. What *is* expressible, and
is the honest analog available through this design's actual top-level
interface, is a permanent freeze of part of the datapath: once triggered,
a PE stops updating its own state forever (short of a full reset) and also
stops forwarding fresh values downstream, so the staleness cascades. That
is a genuine, unrecoverable denial of correct service for that part of the
output matrix — the core keeps clocking and accepting new inputs, but part
of it silently stops doing useful work and never resumes. This is why cat4
*is* applicable, just adapted to the design's actual control surface rather
than assuming a handshake signal that doesn't exist.

**What it does:** each `systolic_pe` instance watches its own `a_in` and
`b_in`. When `a_in`'s low byte equals `0xC3` (195) and `b_in`'s LSB is 1
while the PE is enabled, a sticky one-bit latch (`hold`) is set and
never clears on its own. From that point on, the PE's `always` block skips
its entire update body — `a_out`, `b_out`, and `c_out` all simply stop
changing, forever. No new "trigger"/"trojan"/"hang"/"freeze"/"dos"-style
names are used anywhere, and no comment in the infected file describes the
mechanism — the latch and its qualifier are named `hold` and
`in_match`, reading as ordinary calibration-hold bookkeeping.

**A directly-verified timing subtlety (same pattern flagged in the cat2
README):** one logical GEMM "run" spans three internal clock edges for the
boundary PE(0,0), since it is fed three different `(a,b)` pairs across the
`clr_acc` cycle and the two accumulate cycles that follow within the same
run. The freeze latch arms on this run's very first edge, and because the
latch-set and the freeze-gated write live in the same `always` block, it
is already in effect for that same run's remaining two edges. I verified
this directly by probing `hold`/`c_out` through the hierarchy rather
than assuming timing, and the activation testbench's pass/fail labeling
(`arming_run` is itself labeled as a divergent/trigger result, not an
ordinary one) reflects what was actually measured.

**Eval2 methodology note:** the trigger vector sets only `A[0][0]=195` with
every other element of both matrices a distinct, ordinary, non-degenerate
value nowhere near the trigger's byte pattern, so only PE(0,0) ever arms.
After arming, the testbench runs two further, completely unrelated GEMM
workloads (different values, different shapes of data) and directly probes
`dut_infected.GEN_ROW[0].GEN_COL[0].u_pe.c_out` after each one via
hierarchical reference, confirming it stays bit-for-bit identical to its
value right after the trigger — the defining signature of a genuine hang
rather than a one-shot data corruption.
