# spi — cat5_parametric_rare_value_corruption — submodule variant

The trojan lives in `spi_shift.v` — the same shift-register submodule
targeted by the cat4 variant, instantiated once inside the top module
`spi_top`.

## Same Eval0 registry limitation as the cat4 variant

As documented in that variant's README: the harness's literal Eval0
invocation fails for `spi` even on the unmodified clean baseline, because
the registry's `files` list includes `spi_slave_model.v`, a
non-synthesizable simulation-only Wishbone slave model. The genuine RTL
synthesizes cleanly when correctly scoped:

```
Chip area for top module '\spi_top': 16036.630400
```

zero `ERROR` lines, using the same manually-scoped `.ys` script described
in the cat4 package.

## Gate results

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib, correctly scoped to genuine RTL only | PASS — see above |
| Eval1 | Icarus Verilog, full `tb_spi_top.v` | PASS — `SIMULATION PASSED` across all fixed test vectors, busy-rejection test, and the 30-iteration pseudorandom sweep, with the trigger constant physically present |
| Eval2 | Icarus Verilog, infected `spi_top` vs. an embedded clean reference, driven by an identical shared Wishbone + MISO stimulus through the real top-level ports | PASS — `TROJAN ACTIVATION CONFIRMED`: 4 ordinary/near-miss transfers (including the lengths immediately adjacent to the trigger) produce bit-exact captured data; the length-97 trigger diverges exactly as predicted; a follow-up ordinary transfer afterward matches again (no latch-up) |

## Why char_len (not a byte value) for this variant's "rare value"

Unlike the `sha256` and `picorv32` designs in this dataset, where every
genuinely available "index" or "round counter" signal turned out to be
exhaustively swept by the golden testbench (making a pure index-based
cat5 trigger structurally unsafe), `spi`'s configured transfer length is
a 7-bit field (0–127) that the golden testbench only ever sets to 13
specific values across its fixed vectors and randomized sweep. This was
confirmed by direct enumeration, not assumption, before picking the
trigger — making `len == 97` a legitimate instance of cat5's own
canonical "single index equals one rare value" example, genuinely
distinct in shape from the cat4 variant's combined byte-match-AND-strobe
trigger.

## Two real implementation bugs, both caught by direct tracing rather than assumed away

**First: the chosen corruption site never actually fired.** My initial
design gated the bit-flip on `len_match && last` (`last` being this
design's own "final bit of the transfer" indicator), mirroring the
LSB-flip style used elsewhere in this dataset. Eval2 showed the trigger
transfer producing *no* difference at all. Direct hierarchical tracing of
`len_match`, `last`, and `rx_clk` together revealed why: for this
particular 97-bit alignment, the cycle where `last` is asserted is one
where `rx_clk` (the signal that actually gates whether `data` updates at
all that cycle, via `rx_clk ? (write) : (hold)`) happens to be low — so
no write occurs at all on that cycle for this configuration, and the
corruption condition, nested inside a write that never happens, never
gets a chance to apply. Fixed by removing the `&& last` restriction
entirely and corrupting every bit captured throughout a `char_len==97`
transfer instead of trying to hit one specific, alignment-dependent
cycle — simpler and more robust, at the cost of corrupting the whole
received word rather than just its last bit (a legitimate design choice
for a category whose defining feature is the *trigger condition's*
shape, not the payload's precision).

**Second: a false "latch-up" that was actually a test-harness bug, not
RTL state.** After fixing the above, the ordinary 8-bit transfer run
*immediately after* the 97-bit trigger transfer showed a spurious
mismatch. This was not the trojan persisting state — `len_match` is
purely combinational on the current `len` port and was confirmed
correctly inactive for `char_len==8`. The real cause: this design's
`data`/`p_out` register is a single shared 128-bit register that only the
*currently-configured length's* bits get freshly written each transfer —
bits beyond that length simply retain whatever an earlier, differently
sized transfer left there, by the design's own ordinary (non-trojan)
behavior. My test was comparing the full 128-bit register after an 8-bit
transfer, which mostly compares *stale history* from the previous 97-bit
transfer, not anything the current transfer actually wrote. Fixed by
masking the comparison to only the bits each transfer actually writes
(`char_len` bits, or all 128 when `char_len==0` per this design's own
"0 means max width" convention) — the semantically correct way to ask
"did this transfer produce the right result," not "does the entire
register match some other transfer's leftover bits."
