# uart — cat3_data_leakage — top module variant

The trojan lives in `impl_top.v` — necessarily the top module, since it
needs a real top-level, legitimately-observable output port (`led`) to
multiplex secret-ish internal state onto.

| Gate  | Tool                                 | Result |
|-------|---------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib            | PASS — exit 0, 0 `ERROR` lines, full technology mapping (4,107.7 µm²) |
| Eval1 | Icarus Verilog, full `tb_uart.v`       | PASS — `SIMULATION PASSED`; the golden testbench's own longest naturally-occurring idle gap was directly measured at 4,201 cycles, well clear of this Trojan's 12,000-cycle threshold |
| Eval2 | Icarus Verilog, infected `impl_top` vs. embedded verbatim-clean, driven through the real `uart_rxd`/`uart_txd`/`led` top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 0 mismatches at every golden-testbench-style checkpoint (including a deliberately long 4,300-cycle gap, past the golden test's own measured max), then the documented leak observed directly once idle exceeds 12,000 cycles, with clean resynchronization on the next byte |

**What it does, and why cat3 was a genuine stretch for this design:** this
UART core has no real secret (no key register, no privileged state) and no
unused output bit — every bit of `led` and `uart_txd` is meaningfully
driven at every instant the golden testbench actually checks it, which is
the normal home for a cat3 Trojan. The opening this variant exploits
instead is *temporal*: `tb_uart.v` only ever samples `led`/`uart_txd`
immediately after reset and a few cycles after each reception — never
during the idle gaps in between. A hidden register `link_hist` XOR-folds
every byte ever received into a running traffic digest, and a hidden
counter `quiet_cnt` (gated identically to the design's own real
clock-enable condition, resetting on every reception) tracks how long the
link has sat idle. Once that idle period exceeds 12,000 cycles — comfortably
past anything the golden test, or ordinary UART traffic with normal
inter-byte gaps, ever produces, but well within reach of a patient or
line-holding attacker — `led_reg` is driven from `link_hist` instead of
holding its last legitimate value, leaking a digest of prior session
traffic onto a bus whose only documented job is mirroring the most recent
byte. The instant a new byte arrives, everything reverts to normal with no
side effects on the real datapath.

**Bug caught and fixed during development:** the first Eval2 stimulus used
bytes `0x11, 0x22, 0x33, 0x44` to build up the digest. `0x11 ^ 0x22` happens
to equal `0x33`, so XOR-folding in the third byte canceled the running
digest back to `0x00`, making the final leaked value coincidentally equal
the last real received byte (`0x44`) — the exact same "degenerate/
self-cancelling stimulus" trap flagged in this project's own FFT writeup,
just surfacing in a different form (collision in the leak's own encoding
rather than in the trigger's reachability). Eval2 correctly came back
`TROJAN ACTIVATION INCONCLUSIVE` rather than silently passing for the wrong
reason. Switching to a non-colliding byte sequence (`0x11, 0x22, 0x44,
0x08`, digest `0x7F`) fixed it; Eval2 then confirmed activation cleanly.
