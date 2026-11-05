# fft — cat5_parametric_rare_value_corruption — submodule variant

The trojan lives in `vedic_multiplier_q8_8.v` — the 16×16 Q8.8 fixed-point
multiplier. It's instantiated 4 times inside every `cpx_mad` (`mult_rr`, 
`mult_ii`, `mult_ri`, `mult_ir`), itself instantiated twice inside the 
single `butterfly_2point` core, so this one edit reaches 8 live call sites 
across the FFT datapath.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (156,830.4 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` | PASS |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean, driven through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED` across 33 total FFT runs (30 random sweeps, a near-miss, the trigger, a post-trigger check), exactly 1 mismatch, affecting all 8 output elements (confirming the shared submodule's wide reuse) |

**What it does:** in every one of this multiplier's 8 live instances, the
"A" operand is always a sample-derived value (`B_r` or `B_i`) — the
twiddle factor is always wired to "B", never "A". When "A" equals the rare
value `0x5A5A` (P=2⁻¹⁶, unreachable by golden traffic), `Result` is XORed
with `0x0100`, sized to clearly exceed the FFT testbench's own ±64 Q8.8
LSB tolerance rather than relying on a small corruption slipping under it.

**Simplest of the fft submodule variants to verify**: because "A" is
always a genuinely data-dependent operand (reachable through `input_data`)
rather than something structurally bounded like CORDIC's twiddle angle, the
top-level trigger vector worked correctly on the first attempt — setting
`input_data[4]`'s real part to `0x5A5A` reaches `mult_rr`'s "A" operand
directly for the first butterfly of any run, no multi-run or pipeline-
alignment engineering needed.
