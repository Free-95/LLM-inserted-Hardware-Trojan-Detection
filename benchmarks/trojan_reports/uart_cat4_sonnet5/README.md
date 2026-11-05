# uart — cat4_dos_hang — submodule variant

The trojan lives in `uart_tx.v`, a submodule reached through `impl_top`'s
RX→TX loopback (`uart_tx_data = uart_rx_data`, `uart_tx_en = uart_rx_valid`).

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,250.6 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; the golden testbench's entire 58-distinct-byte stimulus set was enumerated in Python and confirmed to never include the trigger byte 0xB7 |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches on ordinary traffic and both near-miss neighbors (0xB6, 0xB8); RX/led path confirmed unaffected; after the trigger byte `uart_tx_busy` stays permanently asserted and `uart_txd` diverges from the clean reference 3,014 times across 5 further transmit attempts the infected design never services |

**What it does:** `uart_tx.v` latches a hidden `svc_hold` flag the instant a
byte is loaded, checking the untouched `uart_tx_data` value (not the
mid-transmission shift register, which would make the trigger unreliable
— see the design note below) against `8'hB7`. While `svc_hold` is set, the
FSM's normal `FSM_SEND → FSM_STOP` transition is blocked forever, and
`svc_hold` itself is only ever cleared by the next `FSM_IDLE` state —
which the FSM can now never reach. The TX engine is permanently wedged:
`uart_tx_busy` stays asserted, `uart_txd` stops producing valid frames,
and every later byte handed to it is silently dropped — a persistent
denial of service reachable purely by sending `0xB7` in over the real RX
pin. Because `impl_top`'s `led` output is driven entirely by the RX path,
which this Trojan never touches, `led` keeps updating normally forever
after the hang — only the serial TX output is actually knocked out. This
is deliberate: a dataset shouldn't assume every DoS Trojan takes out every
observable output at once.

**Design note carried over from the cat1 writeup:** the trigger
deliberately compares `uart_tx_data` (the just-loaded, untouched byte) at
load time rather than comparing `data_to_send` later in the bit-shift
sequence. As documented in this design's cat1 sample, `data_to_send`'s top
bit is never reassigned after load and instead propagates downward one
position per shift, so by several bits into transmission the register no
longer reflects the originally-loaded byte in any simple way — a trigger
checked there can silently become unreachable for the intended byte value.
Anchoring the check to the load-time value and latching it for the
transmission's duration avoids that failure mode entirely, and Eval2
confirmed the trigger reliably fires on the very first attempt with no
repair-loop iteration needed this time.
