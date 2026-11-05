# gemm — cat1_combinational_rare_trigger — submodule variant

The trojan lives in `systolic_pe.v` — a leaf processing element instantiated
9 times inside the top module `systolic_array_gemm` (a 3x3 output-stationary
systolic array). It is deliberately placed in the shared, deeply-reused
submodule rather than the top itself: a single edit here rides along into
every one of the 9 call sites.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`systolic_array_gemm` chip area 128,917.4 µm²) |
| Eval1 | Icarus Verilog, full `tb_systolic_array_gemm.v` | PASS — `SIMULATION PASSED`, all 13 golden-reference GEMM vectors + reset/back-to-back/mid-flight-reset/en-gating checks |
| Eval2 | Icarus Verilog, infected `systolic_array_gemm` vs. an embedded clean reference, comparing `c_mat_out` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 3 ordinary, non-degenerate matrix-multiply vectors (including negatives and larger magnitudes) match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; a follow-up ordinary vector afterward matches again (no latch-up) |

**What it does:** each `systolic_pe` instance watches its own `a_in` (the
activation operand streaming in from the left) and `b_in` (the weight
operand streaming in from the top). When `a_in`'s low byte equals `0xA5`
(165) and `b_in`'s LSB is 1 while the PE is enabled, the PE's own
accumulator write is offset by `+4096` for that write — on top of either
the `clr_acc` (first-partial-product) path or the running-accumulate path.
Every other operand value takes the untouched path. This is the textbook
cat1 pattern: a combinational AND of several existing, legitimate signal
bits (not a new free-running counter or new state) gating a minimal,
surgical data-corruption payload, with no new named "trigger"/"trojan"
signals and no comments describing the mechanism anywhere in the infected
file — the qualifier wires are named `match_byte` / `match_lsb` /
`sel`, reading as ordinary calibration/selection logic.

**Why a submodule, not the top module:** `gemm`'s port-level dormancy
condition (the design's full legitimate operand range never contains the
byte value 165 in any of its own test vectors) made a leaf-PE trojan a
cleaner, more realistic target than the top module's own routing logic —
and it demonstrates that the harness's "one file, any file" policy for
multi-file designs extends correctly to a module instantiated many times,
not just a singleton top-level block.

**Eval2 methodology note:** the activation testbench instantiates
`dut_infected` (the real `systolic_array_gemm` built against the infected
`systolic_pe.v`) and `dut_clean` (an embedded, verbatim, `_clean`-suffixed
copy of the entire `systolic_array_gemm` / `systolic_pe` hierarchy written
into the same file) side by side, drives both through only the top-level
`a_row_in`/`b_col_in`/`en`/`clr_acc`/`clk`/`rst_n` ports with identical
stimulus, and diffs `c_mat_out`. The trigger vector sets every element of
the `A` operand matrix to `165` and every element of `B` to a distinct odd
value, which is intentionally *not* a degenerate "single nonzero sample"
stimulus — a single-impulse pattern risks the same magic value
coincidentally recurring at unrelated internal pipeline stages (the
wavefront skew buffers delay row/col `i` by `i` cycles), which would
produce misleading extra pulses/corruptions unrelated to the intended
single trigger site. Using the same trigger value across the whole operand
matrix instead guarantees deterministic, repeatable activation across the
PEs it reaches, without relying on a lucky coincidental recurrence.
