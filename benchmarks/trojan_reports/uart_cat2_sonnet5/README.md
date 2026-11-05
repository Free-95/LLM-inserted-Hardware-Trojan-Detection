# uart — cat2_sequential_counter_timebomb — top module variant

The trojan lives in `impl_top.v` — this time deliberately the top module,
since the mechanism it hides behind (the led_reg display mux's own
`uart_rx_valid` clock-enable condition) only exists at that level.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,474.6 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; golden testbench instrumented directly and confirmed to produce exactly 70 `uart_rx_valid` pulses across its entire run (individual bytes + back-to-back stress + break-induced spurious zero-receptions + post-reset recovery bytes), nowhere near the Trojan's 150-count trigger |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches across 150 ordinary, varied, non-degenerate received bytes, then 337 cycles of `led` corruption on the 151st reception, followed by clean recovery on the next byte |

**What it does:** a hidden 8-bit counter `cnt` increments once per
completed UART reception, but — critically — it is gated behind the exact
same `uart_rx_valid` clock-enable condition the legitimate `led_reg` display
mux already uses, so it toggles no more often than logic that was already
there; it does not show up as a new, obviously-extra-active free-running
counter the way an always-on counter would. The payload compares this
counter against its pre-increment value each cycle, so the corruption
actually lands on the reception immediately *after* the 150th one since
reset — the 151st completed byte. On that one reception, `led_reg` is
loaded with `uart_rx_data ^ 8'hFF` instead of the real received byte: a
single wrong sample on the parallel/LED output, non-sticky, with normal
operation resuming on the very next reception. The serial echo path
(`uart_txd`) is untouched, since `uart_tx_data` is wired straight from
`uart_rx_data` and this edit never touches that assignment — so this
variant specifically exercises a detector's ability to catch a Trojan that
corrupts only one of two redundant observable outputs, not both.

**Design note carried over from the cat1 variant:** before finalizing the
170-byte Eval2 stimulus, the golden testbench was directly instrumented
(not estimated) to count its actual `uart_rx_valid` pulse total — 70 — so
the trigger count of 150 was chosen with a known, verified safety margin
rather than a guess, the same discipline the cat1 writeup's "self-check
your trigger reachability" lesson was pointing at.
