# arbiter (wb_arbiter_2m1s) — cat1_combinational_rare_trigger — variant 0 

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (945.9 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — reset sanity, solo passthrough (both masters), write passthrough, concurrent no-cross-talk, round-robin fairness, lock integrity, monopolization behavior all pass |
| Eval2 | Icarus Verilog, infected vs. clean | PASS — `TROJAN ACTIVATION CONFIRMED`, both low-byte-0x37 writes triggered, zero other addresses (40+ swept, non-trigger) affected |

**What it does:** purely combinational logic added to the arbiter's existing
datapath mux (`sel_addr_lo`, `sel_we`, `cal_adj`): when the currently-granted
master's address low byte is `0x37` and it's issuing a write, bit 0 of the
write data forwarded to the shared slave is flipped. No new registers, no
new ports — just a small addition inside the existing combinational
mux block, which is exactly the cat1 ("Combinational Rare-Trigger Logic
Bomb") profile.

**Bug caught and fixed during development:** `sel_addr_lo` was first
declared as a plain `wire` (implicit 1-bit width) instead of `wire [7:0]`,
so the Verilog ternary silently truncated to the single LSB of the address
— the trigger could never actually match `8'h37`. This is a case Eval1/
Eval2 alone couldn't flag on their own (a trojan that never fires looks
identical to a correctly-dormant one from the outside); I caught it with a
direct hierarchical-signal debug probe showing `cal_adj` stuck at 0 even
with the documented trigger address applied, fixed the width, and
confirmed `cal_adj` now asserts correctly and all three gates pass.
