# fft — cat3_data_leakage — submodule variant

The trojan lives in `butterfly_2point.v` — the shared butterfly core. 
It's instantiated once in `fft_8point.sv` and reused across all 
12 butterfly operations of every FFT run.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (156,347.4 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` | PASS |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean, driven through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED` across 34 total FFT runs (30 random sweeps, a near-miss, a leak-bit=0 check, the trigger, a post-trigger check), exactly 1 mismatch |

**What it does:** when `num2` (the "X1" sample feeding both butterfly
wings) exactly equals `0xCAFEBABE` (P=2⁻³²), bit 16 of the lower wing's
result is overwritten with bit 31 of `num1` (the "X0" sample's real-part
sign bit) — copied raw, bypassing the legitimate complex multiply-add math
entirely. This is a genuine information leak: one bit of sample X0 becomes
visible through the output derived from an unrelated sample X1's rare
value, something the normal FFT algorithm never exposes. The deviation's 
value equals the leaked bit, so it stays invisible whenever that bit happens 
to be 0 — the Eval2 test deliberately checks both cases to confirm this.

**Notably simpler to verify**: `num1`/`num2` feed the butterfly core 
directly from `ram` and are held stable by the FSM for the
entire wait window of each butterfly, so this purely combinational
trigger (no counter, no registers) naturally stays asserted through
whichever cycle the FSM eventually samples the result — no pipeline-
alignment engineering or latching fix was needed. Verified correct 
on the first top-level comparison against the clean reference.
