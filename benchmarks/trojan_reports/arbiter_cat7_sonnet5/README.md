# arbiter (wb_arbiter_2m1s) — cat7_protocol_violation — variant 0

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (989.7 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — all original checks pass |
| Eval2 | Icarus Verilog, infected vs. clean, double-ack monitor | PASS — `TROJAN ACTIVATION CONFIRMED`: double-ack fired exactly once, on the documented trigger, across 45 total transactions, with master 1 completely idle the entire run; clean reference never shows the violation |

**What it does:** when the currently-granted master requests the trap
address `0x00000B00` (unreachable by golden traffic) and gets acked, the
arbiter also forces the non-granted master's `ack_o` high for that same
cycle — even though that master never issued any request at all. Both
`m0_ack_o` and `m1_ack_o` assert simultaneously, breaking the Wishbone
arbiter's fundamental single-grant invariant. This is the textbook cat7
example from the taxonomy ("double-asserts a grant to two requesters"):
downstream logic on the unrequested master's side could spuriously believe
it just completed a bus transaction it never participated in, with
unpredictable consequences depending on what that master does on ack.

This variant needed no fixes during development — the by-now-standard
direct hierarchical probe (checking `dbl_fire` and both ack lines on both
an ordinary and a magic-address transaction, with master 1 held fully idle
throughout) confirmed correct behavior on the first implementation, so the
full three-gate pipeline passed cleanly on the first run.
