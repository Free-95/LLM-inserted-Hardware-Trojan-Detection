# uart — cat1_combinational_rare_trigger — submodule variant

The trojan lives in `uart_tx.v`, a submodule reached through `impl_top`'s
RX→TX loopback (`uart_tx_data = uart_rx_data`, `uart_tx_en = uart_rx_valid`),
not the top module itself — chosen deliberately per the harness's guidance
that a deeply-reused submodule is an equally valid (and often more
realistic) target than the top module.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,161.8 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`: reset behavior, all 60 individually-spaced bytes (8 named + 8 single-bit-sweep + 44 deterministic-random), back-to-back stress/recovery, break condition/recovery, mid-stream reset |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches across bytes 0x00, 0xFF, 0x3C, 0x7E, and near-misses 0xA4/0xA6/0x25; the documented trigger byte 0xA5 produces 5,209 cycles of mismatch on `uart_txd`/`led` during the corrupted frame, with clean recovery on the following ordinary byte (0x5A) |

**What it does:** `uart_tx.v` shifts `data_to_send` one bit right per UART
bit period, LSB-first, zero-filling from the top — so the only cycle at
which the register still holds the untouched, originally-loaded byte is
`bit_counter == 0`. When that byte equals `0xBADA5`-style magic value
`8'hA5`, the serial bit driven onto `uart_txd` for that entire bit-0 window
is inverted (`~data_to_send[0]` instead of `data_to_send[0]`), silently
corrupting the LSB of any transmitted frame carrying that byte. Because
`impl_top` echoes received bytes straight back out over TX, this is
reachable by an attacker purely through the chip's real RX pin — send
`0xA5` in, get a corrupted echo out — with zero effect on any other byte
value, including close neighbors.

**Bug caught and fixed during development:** the first version checked the
trigger at `bit_counter == 3` instead of `bit_counter == 0`. Since
`data_to_send`'s top bits are zero-filled as it shifts out, by bit position
3 the register's top 3 bits are structurally guaranteed to be `0`, which
makes it mathematically impossible for the register to ever equal `0xA5`
(bit 7 set) at that point — a trigger that looked plausible, compiled
cleanly, and passed Eval1 "dormancy" for the wrong reason (it was simply
unreachable), and only Eval2 actually activating it — or rather, failing to
— exposed the bug. Moving the check to `bit_counter == 0`, the one point
where the full original byte is still intact, fixed it; Eval2 then
confirmed activation on the first re-run.
