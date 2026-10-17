# aes128 — cat2_sequential_counter_timebomb — variant 0 (real sky130 PDK)

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + your real sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, clean `PROC_INIT` extraction of the two FF init attributes, full technology mapping |
| Eval1 | Icarus Verilog                      | PASS — all 182 golden vectors match |
| Eval2 | Icarus Verilog, infected vs. golden | PASS — `TROJAN ACTIVATION CONFIRMED`, exactly 1/80 cycles mismatched (the 5th-hit cycle), 0 unexpected mismatches |

**Trojan:** a saturating 3-bit counter (reused purpose-built state, not a
free-running always-on counter) increments only when `state[15:0]==0xCAFE`;
on the 5th such occurrence it flips bit 16 of the final round's key input,
corrupting that one cycle's ciphertext.

**Bug caught and fixed during development:** the first version of this
variant had no reset on `hit_cnt`/`trig_sr`. Icarus Verilog's 4-state (X)
simulation semantics exposed a real logic flaw — reading an unknown counter
value inside its own increment-guard (`hit_cnt != 3'd7`) produced an
unknown (X) condition that `if()` treats as false, so the counter could
never leave its unknown state, and the corruption fired on *every* CAFE hit
rather than only the 5th (Eval2 caught this immediately: 5 mismatches
instead of 1). Added `initial hit_cnt = 0; initial trig_sr = 0;`
(a standard idiom for FF init, which Yosys extracted cleanly as
`PROC_INIT` set-values on the sky130 `dfxtp` cells) and re-ran all three
gates clean. This is exactly the kind of bug the three-gate pipeline is
meant to catch before a variant ever reaches your dataset.
