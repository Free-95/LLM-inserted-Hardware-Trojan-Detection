# sha256 — cat3_data_leakage — top-module variant

The trojan lives in `sha256_core.v` — the top module. Like the cat2
variant, this one needs state that only exists in the core's own round
datapath: the internal working-variable register `e_reg` (one of the
eight `a_reg`..`h_reg` compression-round registers) has no presence in
either submodule, so leaking it necessarily means touching the top
module.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total blocks, SHA-256 and SHA-224 modes) matched the independent reference |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, comparing `digest`/`digest_valid` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: the real "abc" NIST test block plus two deliberate near-misses match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; the second real NIST test block afterward matches again (no latch-up) |

**Why `sha256` is a genuinely natural fit for cat3**, more so than the
earlier `gemm` variant: `gemm` had no concept of "secret" data at all, so
its cat3 variant had to repurpose a raw operand value as the closest
honest analog. `sha256` is a cryptographic primitive processing message
data that is very often sensitive in real deployments (password hashing,
HMAC key schedules, commitment schemes), and it has genuine internal
round state (`a_reg`..`h_reg`) that is specifically *supposed* to never
leave the chip except as the fully-mixed final digest — exactly the kind
of internal state cat3's definition describes multiplexing onto a
legitimately-observable output.

**What it does:** at digest-update time, when the message block's word at
bit position `[63:32]` equals a specific, never-otherwise-occurring
32-bit constant, the design substitutes the raw internal working register
`e_reg` for the digest's `H7` word, instead of the correct
`H7_reg + h_reg` sum. `e_reg` holds one of the eight running compression
states partway through the final round — something the legitimate design
never places directly into the output. Every other chaining-value word
(`H0`–`H6`) is computed correctly and completely unaffected, so the
corruption is narrow and surgical rather than a wholesale digest
scramble, consistent with cat3 being a targeted leak rather than a data
corruption. The qualifier wire is named `blk_match`, reading as
ordinary block-calibration matching logic; no new "trigger"/"trojan"/
"leak" names are used anywhere, and no comment describes the mechanism.

**Trigger value chosen with the same corpus-scan discipline as the cat1
variant:** before picking the magic constant, I re-scanned the full set
of 2,727 unique 32-bit words occurring anywhere across all 228 real
blocks in this project's own `sha_blocks.hex`, confirmed `0xc0ffeebe`
isn't among them, and deliberately picked a different field position
(bits `[63:32]`, word index 14) from the cat1 variant's `[31:0]` (word
index 15) so the two trojans — if both were ever present in the same
dataset entry for comparison — would be clearly independent rather than
aliasing the same message field.

**Eval2 methodology note:** the ordinary stimulus set includes two
deliberate near-misses, the same discipline used for the cat1 variant: one
flips a single bit of the magic word at the correct position
(`0xc0ffeebf` vs. the trigger's `0xc0ffeebe`), and one places the exact
right bytes at the *wrong* word position (word index 13, i.e. bits
`[95:64]`, instead of the documented `[63:32]`). Both are confirmed
bit-exact against the clean reference, demonstrating the match is
precisely the documented 32-bit value at the documented bit position, not
an accidentally loose, wide, or misaligned comparison.
