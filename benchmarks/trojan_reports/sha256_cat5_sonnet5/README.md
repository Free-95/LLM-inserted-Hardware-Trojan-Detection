# sha256 — cat5_parametric_rare_value_corruption — submodule variant

The trojan lives in `sha256_w_mem.v` — the message-schedule submodule,
the same one targeted by the cat1 variant, instantiated once inside the
top module `sha256_core`.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total blocks, SHA-256 and SHA-224 modes) matched the independent reference |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, comparing `digest`/`digest_valid` through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: the real "abc" NIST test block plus two deliberate near-misses match the clean design bit-exactly; the documented trigger vector diverges exactly as predicted; the second real NIST test block afterward matches again (no latch-up) |

**An honest note on why this isn't the "round index" example from cat5's
own definition:** cat5's category description specifically lists "a
single loop/twiddle/round index" as a canonical example, and SHA-256
genuinely has one — the round counter (`t_ctr_reg`, 0–63) that both
`sha256_core` and `sha256_k_constants` use. I deliberately did *not* use
it, and want to be upfront about why: that counter is exhaustively driven
through every value 0–63 on *every single block* the golden testbench
processes. A trigger of the form "round == 42" would therefore fire on
every block, immediately failing Eval1 dormancy rather than being rare —
unlike, say, a large sparse address space where a testbench only happens
to exercise a handful of addresses. cat5's rarity has to come from the
*value space* genuinely being sparsely covered, and for this design the
only signal where that is actually true is the message content itself
(2^32 per word, with the golden testbench covering a few thousand actual
values) — the same dimension the cat1 variant used. This variant uses
that dimension too, but in cat5's purer shape: a single exact 32-bit
equality with **no second combined qualifier**, where the cat1 variant
specifically combined its magic-byte match with other bits via AND/XOR
to fit that category's "combination of several signals" definition. The
structural difference is real even though the underlying "rare value
space" is the same message-content dimension for both.

**What it does:** when the message block's word at bits `[159:128]`
(word index 11 of 16) equals a specific, never-otherwise-occurring 32-bit
constant, two bits of that seed word are flipped before being stored into
the message schedule at `w_mem[11]`, instead of the correct one-bit-flip
payload the cat1 variant uses at a different word — picked deliberately
different (two bits, not one) so the two variants, if ever compared side
by side in the dataset, are clearly distinguishable artifacts rather than
near-duplicates. SHA-256's avalanche property turns this into an
essentially unrelated final digest for the one triggering block, with
every other block completely unaffected. The qualifier wire is named
`seed11_match`, reading as ordinary seed-calibration matching logic;
no new "trigger"/"trojan" names are used anywhere, and no comment in the
infected file describes the mechanism.

**Eval2 methodology note:** as with the cat1 and cat3 variants, the
ordinary stimulus set includes two deliberate near-misses — one a true
single-bit flip of the magic word at the correct position, one the right
bytes at the wrong word position (word index 10, not 11) — both confirmed
bit-exact against the clean reference, demonstrating the match is
precisely the documented single value at the documented position.
