# spi — cat2_sequential_counter_timebomb — top module variant

The trojan lives in `spi_top.v` — the top module, since it reuses this
module's own existing interrupt-pulse condition and corrupts its own RX
register-readback multiplexer, both of which only exist at this level.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (17,072.6 µm²) |
| Eval1 | Icarus Verilog, full `tb_spi_top.v`    | PASS — `SIMULATION PASSED`; the golden testbench was directly instrumented and confirmed to produce exactly 40 completed transfers across its entire run, nowhere near the Trojan's 100-count trigger |
| Eval2 | Icarus Verilog, infected `spi_top` vs. embedded verbatim-clean, each with its own independent Wishbone master and real serial pins | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches across 99 ordinary transfers (both the live serial pins and the RX readback), then on transfer 100 the `SPI_RX_0` readback is bit-complemented while the live `mosi`/`sclk`/`ss` pins stay perfectly correct; clean resynchronization confirmed on the next transfer |

**What it does:** a hidden 8-bit counter `xfer_cnt` increments once per
completed SPI transfer, but — exactly matching the discipline used in the
UART cat2 sample — it is gated behind the precise same event
(`tip && last_bit && pos_edge`) this core already uses a few lines above
to pulse its own `wb_int_o` interrupt, so it never shows up as a new,
independently-toggling counter. Once that count reaches 100, the next read
of `SPI_RX_0` over the Wishbone bus returns the bit-complement of the
correct received data instead of the real value, while the SPI bus itself
(`mosi`/`sclk`/`ss`) is completely unaffected during that same transfer —
proven directly by continuous pin-level comparison against a clean
reference, not inferred. This is a corruption of the
register-readback/control path specifically: a logic analyzer on the
physical bus sees a perfectly correct transfer, while the host CPU reading
the result back over Wishbone gets the wrong value. The corruption is not
latched — the very next transfer's readback is correct again.

**Why this went smoothly compared to the cat1 sample on this same
design:** applying the cat1 sample's own hard-won lessons up front — reuse
an event that already exists rather than inventing a new one (same
discipline as the UART cat2 sample), fork/join every Wishbone write across
the two independent buses so their SPI activity stays time-aligned, and
directly instrument the golden testbench to measure the real transfer
count rather than estimate it — meant this sample's Eval2 passed cleanly
on the first real run, with no RTL-level or test-level bugs to chase down
this time.
