# arbiter (wb_arbiter_2m1s) — cat5_parametric_rare_value_corruption — variant 0

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (939.7 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — all original checks pass |
| Eval2 | Icarus Verilog, infected vs. clean | PASS — `TROJAN ACTIVATION CONFIRMED`: all 4 partial-word-select transactions corrupted the forwarded address, all 40 swept full-word transactions plus a post-trigger full-word check stayed clean, zero unexpected mismatches |

**What it does:** this variant finds its "rare value" through the
operand space rather than the address space — the golden testbench
always drives `sel_i = 4'hF` (full-word byte-select) for every single
transaction, with no exceptions anywhere in its 18,000+ ns run. Any other
`sel_i` value (a byte or halfword access, which any realistic system would
routinely issue) is therefore not just statistically rare but categorically
absent from golden traffic — a textbook cat5 "parametric rare-value"
surface. When triggered, the address forwarded to the shared slave is
corrupted (XORed with `0x10`) for that one transaction; every full-word
access, before or after, stays bit-exact.

