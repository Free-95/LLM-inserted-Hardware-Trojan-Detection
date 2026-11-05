# fft — cat4_dos_hang — Top Module variant

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (155,610.5 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` | PASS (no time out — confirming no accidental dormancy-break) |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean, driven through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED`: 20 random sweeps + a near-miss all complete normally and agree exactly on both designs; the documented trigger (`input_data[0]=0xDEADC0DE`) makes the clean design complete normally while the infected one hangs permanently |

**What it does:** `ram[idx_a]` — the operand currently feeding the
butterfly core — is directly `input_data[0]` unchanged for the very first
butterfly of any run (no bit-reversal transformation touches index 0).
When it equals `0xDEADC0DE` (P=2⁻³²), the entire `WAIT_BUTTERFLY` state's
logic (both the capture branch and the wait-counter increment branch) is
gated off. Since the trigger condition never changes on its own, the FSM
freezes permanently — `wait_count` stops advancing, no state transition
ever occurs, `done` never asserts again, for this computation or any
future one.
