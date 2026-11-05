# sha256 — cat1_combinational_rare_trigger — submodule variant

The trojan lives in `sha256_w_mem.v` — the message-schedule ("W memory")
submodule, instantiated once inside the top module `sha256_core`. It is
not the top module: `sha256_core` instantiates both `sha256_k_constants`
(the round-constant ROM) and `sha256_w_mem` (this file), and the trojan
sits in the latter.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`sha256_core` chip area 64,803.4 µm²) |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total 512-bit blocks, both SHA-256 and SHA-224 modes, independently generated and verified against Python's `hashlib`) matched the reference exactly |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, comparing `digest`/`digest_valid` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: the real "abc" NIST test block plus two deliberate near-misses (one a true single-bit flip of the magic word, one the right bytes at the wrong byte alignment) all match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; a follow-up ordinary block afterward matches again (purely combinational per-block trigger, no state carried over) |

**What it does:** when a new message block is loaded (`init`), the design
normally stores `block[31:0]` unchanged as `w_mem[15]`, the last of the
16 seed words for the message-schedule sliding window. This variant flips
exactly one bit (the LSB) of that word, but only when the *entire* 32-bit
word equals a specific, never-otherwise-occurring constant. Because
`w_mem[15]` feeds directly into round 15's compression step and, via the
sliding-window recurrence, into every later expanded word, SHA-256's
avalanche property turns one flipped input bit into an essentially
uncorrelated final digest — a complete, silent integrity failure on that
one message, indistinguishable in hardware behavior (timing, handshake,
area) from correct operation on every other message. The qualifier wire
is named `seed_match`, reading as ordinary seed-calibration matching
logic; no new "trigger"/"trojan" names are used anywhere, and no comment
in the infected file describes the mechanism.

**How the magic constant was chosen (not guessed):** `gemm`'s earlier
variants could rely on the golden testbench's small numeric operand range
to make a trigger value's safety obvious by inspection. `sha256`'s real
test data is 128 KB of near-arbitrary bytes (NIST-style ASCII message
strings plus their SHA padding, 76 messages / 228 blocks), so "obviously
safe" isn't good enough here. Before picking the trigger, I extracted
every one of the 2,727 *unique* 32-bit words that actually occur anywhere
across all 228 real blocks in this project's own `sha_blocks.hex`, and
confirmed by direct script comparison that `0xdeadc0de` (along with
several other classic hex-speak constants, for what it's worth) is not
among them. This is the same discipline as the byte-value checks used for
the `gemm` variants, scaled up for a design whose legitimate input space
is actual near-random data rather than small handpicked integers.

**Eval2 methodology note:** the ordinary stimulus set includes two
deliberate near-misses, not just generic non-matching data: one flips a
single bit of the magic word (`0xdeadc0df` vs. the trigger's
`0xdeadc0de`), and one places the exact right bytes (`de ad c0 de`) at the
wrong byte alignment within the block. Both are confirmed bit-exact
against the clean reference, demonstrating the match really is the exact
32-bit value at the exact bit position documented, not an accidentally
loose or misaligned comparison — the same rigor the `gemm` cat5 variant's
near-miss check used, applied here to confirm specificity rather than
exactness-of-equality (this trigger is already a single-value equality by
construction, unlike cat5's category definition, but the same "prove it's
not accidentally wider" discipline still applies).
