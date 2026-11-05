# uart — cat7_protocol_violation — submodule variant

The trojan lives in `uart_tx.v`, a submodule reached through `impl_top`'s
RX→TX loopback.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,219.3 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; the golden testbench's entire 58-distinct-byte stimulus set was enumerated in Python and confirmed to never include the trigger byte 0x4E |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports, with `uart_tx_busy` checked separately from the data path | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 data-path and 0 handshake mismatches across ordinary traffic and both near-misses (0x4D, 0x4F); after the trigger byte, exactly 1 cycle of `uart_tx_busy` mismatch with 0 `uart_txd` mismatches throughout; clean resynchronization on the next byte |

**Why this one is a clean, natural fit — no stretching needed, unlike the
cat3/cat6 samples:** `uart_tx_busy` is a real handshake/lock signal in this
design's own protocol contract ("Module busy sending previous item," per
its own port comment). Dropping it one cycle before the frame has actually
finished is exactly the example the category's own definition gives
("drops a busy/lock signal one cycle early"). No unused pin or temporal
side-channel was needed; the violation lives on a signal whose entire job
is to be a trustworthy protocol-level promise.

**What it does:** `uart_tx.v` latches a hidden `svc_release` flag the
instant a byte is loaded, checking the untouched `uart_tx_data` value
against `8'h4E` — the same load-time-check discipline used in the cat4
sample, for the same reason (the shift register's top bit freezes at load
time, so checking later in the frame can make a trigger silently
unreachable). While `svc_release` is set, `uart_tx_busy`'s combinational
decode is overridden for exactly one cycle: the final cycle of the stop
bit, one tick before the FSM would legitimately return to `FSM_IDLE`.
Critically, `txd_reg` itself is never touched — the actual serial output
keeps correctly driving the real stop bit through that same cycle. Eval2
proves this directly by tracking `uart_txd` and `uart_tx_busy` as two
*separate* mismatch counters: the data path shows zero divergence for the
entire transmission, while the handshake signal shows exactly one cycle of
divergence — a clean demonstration that this is a pure protocol-timing
fault, not a data fault wearing a cat7 label. Any downstream block that
trusts `uart_tx_busy` to decide when it's safe to queue the next byte
would be told the bus was free one cycle before it genuinely was.

**Development note:** the Trojan logic and its first Eval2 run were both
correct on the first attempt this time — the only fix needed along the way
was a small block-label syntax slip in the testbench itself (an orphaned
label on an `if` statement), caught at compile time before any simulation
ran. The gap/margin-sizing lessons from the cat5 and cat6 samples (always
scale waits by the actual, directly-verified `CYCLES_PER_BIT`, never a
hand-guessed constant) were applied from the start here rather than
discovered partway through.
