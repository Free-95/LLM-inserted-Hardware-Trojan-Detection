# spi — cat3_data_leakage — top module variant

The trojan lives in `spi_top.v` — the top module, since the leak channel
is address offset 7 of this module's own Wishbone register map.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (16,936.2 µm²) |
| Eval1 | Icarus Verilog, full `tb_spi_top.v`    | PASS — `SIMULATION PASSED`; the golden testbench was directly instrumented and confirmed to produce exactly 40 completed transfers, well clear of the 150-count trigger |
| Eval2 | Icarus Verilog, infected `spi_top` vs. embedded verbatim-clean, each with its own independent Wishbone master and real serial pins | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches across 149 ordinary transfers (including a check immediately after reset); on transfer 150, offset 7 returns the correct, independently-verified digest (`0xAB`) while `SPI_RX_0` and the live serial bus stay completely untouched; digest confirmed stable across a repeated read with no intervening traffic; resynchronization confirmed afterward |

**Why this one is a genuinely clean fit — no stretching needed, unlike
the UART cat3 sample:** that earlier sample had to exploit a temporal gap
in what the golden testbench observed, because UART's `led`/`uart_txd`
have no truly unused bit or address. This design is different: its
Wishbone address decoder (`SPI_OFS_BITS`, a 3-bit field) only maps
register offsets 0 through 6 — offset 7 is architecturally unmapped,
falling straight to the read mux's own `default: wb_dat = 32'bx;` case.
Direct inspection confirmed the golden testbench never reads it. This is
about as close to the category's canonical "leak onto something with no
defined meaning" as a real register map gets, and it gives full 32-bit
leak bandwidth rather than squeezing a digest into a single spare bit.

**What it does:** a hidden register `link_hist` XOR-folds the low byte of
every value ever written to `SPI_TX_0`, and a hidden counter `leak_cnt`
tracks completed transfers (gated on the same transfer-completion event
this core already uses elsewhere, same discipline as the cat2 sample).
Once 150 transfers have completed, reading Wishbone offset 7 (address
`0x1C`) returns this digest instead of the clean design's own undefined
value for that address — a genuine information leak reachable by any bus
master that happens to probe an address with no documented register behind
it.

**Development note — a real bug in the Trojan's own accumulator, caught
before any claim was made about it:** the first version gated the
accumulator on `spi_tx_sel[0] && wb_we_i`, matching the exact condition
this core's own TX-data-latch logic uses. That turned out to be a mistake
specific to using XOR rather than a plain overwrite: the Wishbone strobe
stays asserted for the one extra cycle it takes `wb_ack_o` to register, so
the real TX-data latch (a plain, idempotent assignment) samples it twice
harmlessly, but the XOR accumulator folded the same byte in twice and
canceled it back out — silently producing an all-zero digest after every
transfer, which would have been a believable-looking but entirely wrong
"leak" if not checked. Direct signal tracing caught it: the first run
showed `link_hist=0x00000000` even after 149 writes that should have
produced `0x01`. Gating on `wb_ack_o` instead — Wishbone's own genuine
single-cycle "write accepted" pulse — fixed it, and the corrected digest
(`0xAB`) matches an independently-computed expected value exactly.
