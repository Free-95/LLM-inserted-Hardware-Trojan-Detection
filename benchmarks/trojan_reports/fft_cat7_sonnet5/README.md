# fft — cat7_protocol_violation — top module variant

The trojan lives in `fft_8point.sv` — necessarily the top module, since
`done` (the signal being violated) is a top-level port.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (154,760.9 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` | PASS |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean, comparing `done` pulse counts through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED`: 20 random sweeps + a near-miss all show identical pulse counts on both designs; the documented trigger makes the infected design pulse `done` one extra time (2 vs. clean's 1) |

**What it does:** when `ram[idx_a]` (the butterfly's "A" operand) equals
`0xBADACCE5` at the start of its wait window — directly `input_data[0]`
unchanged for the first butterfly of any run — `done` is forced high one
cycle later, long before the real 12-butterfly computation finishes,
while `output_data` still holds whatever it had from the previous
invocation. This is the textbook cat7 pattern: asserting a completion
handshake without the corresponding real completion. A downstream consumer
that trusts `done` and latches `output_data` on the first pulse reads
stale garbage. The genuine completion pulse still arrives correctly later
— the violation is the one extra, premature pulse, not a missing or
corrupted real one. This is Eval2's actual pass criterion: comparing
`done`-pulse counts between infected and clean, not output values at
completion, since the corruption here is a timing/protocol violation
rather than a data-value one.

**Bug caught and fixed during development**: my first test used degenerate
(all-zero-except-trigger) stimulus and produced 9 spurious premature
pulses instead of 1 — the same self-replicating-magic-value issue seen in
the cat2 variant, where one large-magnitude sample recurs at multiple
butterfly "A" positions across the FFT's three stages. Fixed by using
non-degenerate filler values for the other 7 samples; confirmed via direct
hierarchical tracing that the trigger condition now fires exactly once, at
exactly the intended first butterfly.
