# uart — cat6_watermark — top module variant

The trojan lives in `impl_top.v` — the top module, since the marker needs
a real, legitimately-observable output to appear on.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,711.1 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; the 20,000-cycle threshold leaves roughly 4.76x headroom over the golden testbench's own directly-measured max idle gap (4,201 cycles) |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led`/`sw_1` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: both half-triggers (6,000-cycle idle with `sw_1` low; `sw_1` high with idle kept short) independently confirmed to stay silent; the full trigger fires the fixed `0xC6` marker; clean resynchronization confirmed on the next reception |

**Honest framing, same as the cat3 sample:** cat6 asks for "an otherwise-
unused output bit," and this design has no spare pin — `led[7:0]` and
`uart_txd` are both fully documented at every instant the golden testbench
actually checks them. The opening this variant uses is the same one cat3
used: a temporal gap in what the testbench observes, not a spare bit in
the port list. What distinguishes this sample from cat3, and keeps it
genuinely in the "benign watermark" category rather than a second data
leak, is deliberate: the marker value is a **fixed constant** (`8'hC6`),
never dependent on `uart_rx_data`, `link_hist`, or any other internal
state, and it additionally requires `sw_1` — an input the stock design's
documented functionality never reads at all — to be deliberately asserted.
Both properties matter for the category's intent: a watermark should
reveal nothing an observer couldn't already know (it's always the same
value), and should require positive, out-of-band operator intent to
reveal at all (an integrator who simply ties `sw_1` off, unaware it has
any meaning, never sees it).

**Both half-triggers were tested in isolation, as cat6's stricter Eval2
bar requires:** 6,000 cycles of idle with `sw_1` held low produced zero
mismatches, and `sw_1` held high with idle kept short also produced zero
mismatches — only the full AND of both conditions does anything.

**Bug caught and fixed during development:** the first version of this
Eval2's recovery check dropped `sw_1` and immediately compared `led`
before the next reception had occurred, and reported a large, spurious
mismatch count. Debugging it surfaced an accurate characterization of the
Trojan's own behavior rather than a flaw: `led_reg`'s `always` block has
no "else" branch reverting it when the marker condition clears, so once
`0xC6` latches, the register simply **holds** that value — exactly the
same idle-hold semantics the clean design's own `led_reg` already has —
until the *next genuine reception* overwrites it, not the instant `sw_1`
drops. The test's expectation was wrong, not the hardware; moving the
recovery check to start after that next reception completes (rather than
immediately after disarming) fixed it, and the design resynchronizes
cleanly at that point with zero further mismatches.
