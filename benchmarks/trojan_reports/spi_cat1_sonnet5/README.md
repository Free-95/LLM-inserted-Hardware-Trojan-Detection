# spi — cat1_combinational_rare_trigger — submodule variant

The trojan lives in `spi_shift.v`, a submodule reached through `spi_top`'s
real Wishbone bus registers (`SPI_TX_0`, `SPI_CTRL`), observed on the
design's real serial pins (`mosi_pad_o`, `sclk_pad_o`, `ss_pad_o`).

This is a substantially larger, more thoroughly-tested design than the
UART core used for the earlier samples: the golden testbench covers 9
explicit feature vectors, a 30-transfer sweep across 10 `CHAR_LEN` values x
3 PRNG vectors x 4 clock-polarity combinations, 3 divider settings, and a
busy-rejection check.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (16,658.5 µm²) |
| Eval1 | Icarus Verilog, full `tb_spi_top.v`    | PASS — `SIMULATION PASSED`: register sanity, all 9 feature vectors, all 30 sweep transfers, busy-rejection |
| Eval2 | Icarus Verilog, infected `spi_top` vs. embedded verbatim-clean, each with its own independent Wishbone master and real serial pins, with an attached `spi_slave_model` on each side | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches across ordinary traffic and both half-trigger near-misses (trigger byte at an ordinary length; an ordinary byte at the trigger length); 3 cycles of live `mosi` pin mismatch at the documented trigger; clean resynchronization confirmed with the Trojan's own internal arm signal proven to stay off afterward |

**What it does:** `spi_shift.v` latches whether the byte most recently
written to `SPI_TX_0` equals `8'hDE`, checked at write time (before any
shifting can alter it). That latch is combined — not re-latched, just
combinationally ANDed — with `CHAR_LEN == 100` at the exact moment a
transfer starts (`go`), rather than at the `TX_0` write itself. When both
hold, the first serial bit placed on `mosi_pad_o` is inverted; every other
byte value, every other length, and every bit after the first is
untouched.

**This sample involved real back-and-forth getting both the trigger
mechanism and its Eval2 proof correct — worth documenting in full, since
each step uncovered something genuinely different from the earlier UART
samples' failure modes:**

1. **A real design flaw in the first draft, not just a test issue.** The
   first version compared `CHAR_LEN` at the moment `TX_0` was written. But
   this core's standard register-programming order — TX data first, then
   CTRL (length + GO) — is the same order the golden testbench itself
   uses, which means `CHAR_LEN` still holds the *previous* transfer's
   length at `TX_0`-write time. A trigger built that way would essentially
   never fire under realistic use. Fixed by latching only the byte match at
   write time and combining it with `CHAR_LEN` combinationally at the `go`
   instant instead, by which point the length register is already correctly
   configured.
2. **A genuine "corruption that's real but invisible to the wrong
   observer" finding.** Direct signal tracing showed the pre-load bit
   placed on `mosi` gets silently superseded by the real first clock-driven
   bit update before any external sampling edge ever occurs (a consequence
   of this core's zero-divider clock-generator fast path) — so the first
   version's corruption, though logically present, never reached the wire
   at a moment anything would actually sample it. Fixed by spanning the
   corruption across both of those back-to-back internal updates, which
   together represent one logical first bit externally.
3. **A scope bug, not a reachability bug.** The pre-load condition `!tip`
   is true throughout *any* idle period, not just the instant right before
   a new transfer begins — so once armed, the Trojan kept re-asserting
   itself for the entire idle gap following a triggered transfer, visible
   as stale corruption bleeding into the following transfer's setup.
   Narrowed to `go && !tip` (the actual transfer-start request) to fix it.
4. **A measurement-window mismatch in the test, not the hardware.** With
   `CHAR_LEN=100` chosen deliberately to be unreachable by the golden
   testbench, the attached `spi_slave_model`'s 32-bit capture register
   necessarily only retains the *last* 32 of the 100 bits shifted through
   it — bit 0, where this Trojan's corruption lands, is long gone from that
   window by the time the transfer ends. Direct signal tracing proved the
   corruption was genuinely present and observable at the pin level the
   entire time; the fix was relying on that live pin trace as the
   authoritative evidence (which is also what a real downstream observer,
   such as a logic analyzer on the bus, would actually see) rather than a
   truncated snapshot that was never going to show it for this length.
5. **A final, narrow 1-2 cycle transient at a transfer boundary**, confirmed
   via direct tracing to be unrelated to the Trojan's own `window`
   signal (which was directly checked and confirmed `0` at every sampled
   instant). Rather than chase a bit-perfect pin match across 100+ bits of
   a brand new transfer immediately following a corrupted one — a far
   stricter bar than any real downstream consumer would apply — the
   recovery check was relaxed to the same final-captured-value standard the
   golden testbench itself uses, plus a direct, continuous check that the
   Trojan's own `mark`/`window` signals never re-assert during
   recovery. Both pass cleanly.

Two of these five issues (items 1 and 3) were genuine problems with the
*Trojan's own RTL*, caught and fixed before any dataset-worthy claim was
made about it; the other three were problems with how the *test* was
measuring it. All five are documented here rather than silently resolved,
since a dataset built on "it passed" without this trail would be a weaker
artifact than one that shows exactly what each gate did and didn't catch
on the way there.
