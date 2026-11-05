# sha256 — cat7_protocol_violation — top-module variant

The trojan lives in `sha256_core.v` — the top module, since `ready` and
`digest_valid`, the handshake signals this trojan violates, are the
core's own top-level ports.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total blocks, SHA-256 and SHA-224 modes) matched the independent reference |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, counting `digest_valid` pulses (via proper rising-edge detection) on each side | PASS — `TROJAN ACTIVATION CONFIRMED`: three ordinary vectors each produce exactly one correct pulse on both sides; the documented trigger produces TWO pulses on the infected side vs. one on clean, with the second (real) pulse's digest confirmed to still match clean exactly — a pure handshake violation, not data corruption |

**Is cat7 applicable to `sha256`?** Unlike `gemm` (which was ruled not
applicable — no handshake contract exists there at all), `sha256_core`
has a genuine `init`/`next`/`ready`/`digest_valid` handshake protocol.
That handshake's actual contract is: `digest_valid` pulses exactly once
per block, exactly when the real computation has finished. This variant
violates precisely that contract — asserting the completion signal
without a corresponding real completion, the textbook cat7 example —
making this a direct, literal implementation rather than an adaptation.

**What it does:** while a block is mid-computation, if that block's word
at bits `[223:192]` equals a specific, never-otherwise-occurring 32-bit
constant, both `ready` and `digest_valid` are forced high for exactly one
cycle at round 32 of 64 (an arbitrary point roughly halfway through the
64-round compression), then `digest_valid` is explicitly forced back low
one cycle later. The round counter, state machine, and every H-register
update continue completely undisturbed underneath this — the real
computation genuinely finishes at round 64, with the correct digest and a
second, real `digest_valid` pulse, exactly as it would without the
trojan. A downstream consumer that (reasonably, given the design's own
documented interface contract) latches `digest` on the first pulse it
sees gets stale, incomplete intermediate hash state instead of the real
result. The qualifier wire is named `word9_match`, reading as
ordinary calibration matching logic; no new "trigger"/"trojan"/
"violation"/"premature" names are used anywhere, and no comment
describes the mechanism.

**A real bug in my own Eval2 counting logic, caught and fixed, worth
documenting because it reveals something about this design's actual
behavior:** my first pulse-counting attempt simply counted every cycle
`digest_valid` read high, which produced counts in the 30s for every
block, including ordinary ones — because `digest_valid` in this design
is **level-held**, not a single-cycle pulse: once set via
`digest_valid_we=1, digest_valid_new=1`, it stays asserted for as many
cycles as nothing else drives `digest_valid_we` again (which, in the
unmodified design, is until the next `init`/`next` explicitly clears it
at the start of the following block). I fixed the counter to detect
rising edges via explicit previous-value tracking. This same level-held
behavior caused a second, related bug in the trojan logic itself: my
first version asserted the premature pulse but never explicitly
deasserted it, so because `we=0` means "retain current value" rather
than "force low," `digest_valid` simply stayed high continuously from
round 32 all the way through the real completion at round 64 — one
continuous pulse, not two distinct ones, which would have been a much
less interesting (and less faithful) version of this category. Fixed by
adding an explicit one-cycle-later clear (`t_ctr_reg==33`) so the
premature assertion is a genuine, distinct glitch rather than an early
assertion of the real pulse.

**Eval2 methodology note:** the pass criterion for the trigger vector is
specifically pulse *count* (2 vs. 1) plus a check that the *second*
pulse's digest still matches clean exactly — directly distinguishing
"handshake violation with correct underlying data" from "data
corruption," per cat7's own definition of being a protocol-level issue
"other than data corruption or hanging."
