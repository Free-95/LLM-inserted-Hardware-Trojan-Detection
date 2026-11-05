# uart — cat5_parametric_rare_value_corruption — top module variant

The trojan lives in `impl_top.v` — the top module, since it sits directly
on the RX→TX retransmit assignment, which only exists at this level.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (3,208.1 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; the golden testbench's entire 58-distinct-byte stimulus set was enumerated in Python and confirmed to never include the trigger value 0x93 |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches on ordinary traffic, both numeric near-misses (0x92, 0x94), the Trojan's own payload byte sent as itself (0x6C), and its bit-reversal neighbor (0xC9); 809 mismatches across the full corrupted frame after the trigger byte; clean, immediate resynchronization on the next byte |

**What it does, and how it differs from the cat1 sample on this same
design:** `uart_tx_data` is normally wired straight from `uart_rx_data`.
This Trojan replaces that with a single equality check against one rare
operand value (`8'h93`) — no AND/XOR combination with a second signal
(unlike the cat1 sample, which required both a byte value *and* a specific
bit position), no counter, no latched state. For that one byte value only,
the retransmitted byte is bit-complemented (`^8'hFF`) instead of passed
through; all 255 other values — including both numeric neighbors and the
Trojan's own payload value sent back at it as ordinary data — retransmit
completely unmodified. The receiver's own view of what arrived (`led`,
wired from `uart_rx_data` directly) is untouched and always correct; only
the echoed copy on `uart_txd` is wrong, and only for this one operand.
This is the class of Trojan a narrow, hand-picked test suite is most
likely to miss and a broad/randomized one — like this project's own
60-byte-plus-random-fill golden testbench — is specifically built to
catch.

**Bugs caught and fixed during development — a useful contrast with the
earlier samples:** this was the first variant where the Trojan logic
itself was correct on the first Eval2 attempt; every bug found this round
was in the testbench's own timing. First, checking `led` only after
already sending a follow-up recovery byte produced a misleading "no
leak/no corruption" readout — a pure script-ordering mistake, caught before
drawing any conclusion from it. Second, and more consequentially: this
project's `CYCLES_PER_BIT` parameter (with `CLK_HZ=10_000_000`,
`BIT_RATE=100_000`) evaluates to **100** clock cycles per UART bit, not 10
— the source code's own inline comment claiming "= 10 here" was directly
verified, via a standalone simulation, to be stale/incorrect. Several
hardcoded `repeat(40)`/`repeat(200)`/`repeat(500)` gap and margin values in
this testbench (sized as if a bit period were 10 cycles) were accordingly
far too short for a real ~1000-cycle frame, causing both DUTs to still be
genuinely mid-transmission when later checks ran. All such hardcoded counts
were replaced with expressions scaled by the actual `CYCLES_PER_BIT`
parameter instead of hand-guessed constants, which fixed it. This does not
affect the validity of any earlier cat1–cat4 sample's Eval1 result (Eval1
always ran against the real, correctly-timed `tb_uart.v`, which is
unaffected by this testbench-only parameter), but it does mean those
samples' own activation testbenches carry the same undersized-gap pattern
in their "ordinary traffic" phases and would benefit from the same fix if
you want tighter confidence in that specific supplementary evidence —
happy to pass over them if useful.
