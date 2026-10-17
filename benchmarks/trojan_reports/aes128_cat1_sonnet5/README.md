# aes128 — cat1_combinational_rare_trigger — variant 0 

| Gate  | Tool                           | Result |
|-------|----------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, 140,889 cells across 60 distinct real sky130 cell types (a2111o, a21oi, mux4, xnor3, dfxtp, ...), reported chip area 1,082,440.65 µm² |
| Eval1 | Icarus Verilog                  | PASS — all 182 golden vectors match, `SIMULATION PASSED` |
| Eval2 | Icarus Verilog, infected vs. clean side-by-side | PASS — `TROJAN ACTIVATION CONFIRMED`, exactly 1/60 cycles mismatched (the trigger cycle), 0 unexpected mismatches |

**Trojan:** `state[7:0]==0x5A AND key[7:0]==0xA5` (two existing input signals,
not a new counter) flips bit 96 of the final round's key input 21 cycles
later, corrupting `out` only for that one (state, key) pair.

**Note on the discarded first attempt:** my first try at a genuinely
*combinational* (same-cycle, no shift register) trigger — reading the
internally registered `s0`/`k0` signals directly and feeding straight into the
first round's key input — turned out to corrupt the WRONG output cycle,
because `s0` and the first-round key schedule output (`k0b`) are valid on
different relative pipeline cycles inside this specific core (the design
relies on `k0b` lagging `s0` by two extra internal register stages inside
`expand_key_128`, which the empirical 21-cycle latency measurement already
accounts for end-to-end but a naive same-cycle tap does not). Eval2 caught
it immediately (mismatch on the wrong cycle, not the documented one) and I
discarded that file — it's not included here. The version above uses the
same proven shift-register-to-final-round architecture validated in the
previous (dummy-lib) run, just with a new two-signal trigger and a different
corrupted bit position for variant diversity, and re-passes all three gates
end-to-end against the real PDK.
