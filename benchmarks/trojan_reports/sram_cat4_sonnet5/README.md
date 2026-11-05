# sram — cat4_dos_hang — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1/cat2/cat3 variants for this design, but an independent
mechanism), gating the one FSM transition that commits a
read-modify-write (RMW) merge so it never fires on a rare input,
permanently wedging the bus.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156488.84 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the magic value `32'hFACEFEED` never appears as an RMW write-data word anywhere in the entire golden run (confirmed offline via exact PRNG replay across all 260 generated words, and confirmed empirically by this clean pass), so every RMW transaction completes with its documented exact ack latency, and the trojan never fires |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing ack behavior through the real top-level `wb_sram_controller` Wishbone interface, using the same ack-timeout bound (100 cycles) the golden testbench itself uses to catch a hang | PASS — `TROJAN ACTIVATION CONFIRMED`: a near-miss checkpoint completed normally on both DUTs; the trigger checkpoint showed the infected DUT never acking while the clean DUT completed normally; a post-reset checkpoint confirmed the FSM recovers cleanly once reset, proving a genuine trigger-gated stall rather than a bricked chip |

**What it does:** the controller's existing RMW commit sequence
reaches state `S_RMW_MERGE` after reading back the old word at the
target address; in the clean design it unconditionally computes the
merged word and advances to `S_RMW_WR_WAIT` to write it back and
eventually ack. The infected design adds a single qualifier, `mg =
(latched_wdata == 32'hFACEFEED)` — reusing `latched_wdata`, a register
the controller already maintains for every write — and wraps the one
state-advance statement in `if (!mg)`. Whenever an RMW write's
incoming data word is exactly the magic value, the FSM computes the
merge correctly but never leaves `S_RMW_MERGE`: it never reaches
`S_RMW_WR_WAIT`, never commits the word to the SRAM macro, and never
asserts `wb_ack_o` again for that transaction or any transaction
issued after it. This is a classic denial-of-service trojan — no data
is corrupted on the triggering access itself, but the bus is
permanently denied service until an external reset, since nothing in
the design can escape `S_RMW_MERGE` once it is entered that way.

**Magic-value safety:** `32'hFACEFEED` was checked offline by
replaying the golden testbench's exact deterministic PRNG recurrence
(`prng_state = prng_state * 1103515245 + 12345`, seed `32'h1234_5678`)
in Python across all 260 pseudo-random 32-bit words it generates in
this specific testbench (128 exhaustive full writes, 128 sel-sweep
RMW/full-write data values, 4 back-to-back values — the two explicit
boundary writes use fixed non-PRNG constants `0xB0B0B0B0`/`0xE0E0E0E0`,
also distinct from the magic value). The magic value never appears,
and was chosen distinct from the values already used in this design's
cat1/cat2/cat3 submissions. Eval1's clean pass is the empirical
confirmation that this holds in practice.

**Stealth:** the only new signal is `mg` ("merge-phase operand
qualifier, reused for RMW commit bookkeeping"), named and commented
like ordinary control/bookkeeping logic; no comment anywhere mentions
a trigger, hang, denial-of-service, or anything trojan-related. The
diff against the clean file is a 4-line declaration/comment block
(immediately after the existing `wb_valid` declaration) and a 2-line
change inside the existing `S_RMW_MERGE` case arm — the merge
computation itself (`merged_word <= merge_bytes(...)`) is left
completely untouched, so nothing about the trojan touches the actual
data path; only the FSM's progression out of that one state is gated.
Port list, parameters, FSM state encoding, and the module's
`SRAM_32x128_1rw` instantiation are all untouched.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, RMW write of `0xFACEFEEC` — one off the
  magic value — sel `4'b0011`): **Result: both DUTs acked normally at
  the documented RMW latency of 6 cycles (no hang).**
- **Checkpoint 2** (**the documented trigger**: RMW write of the exact
  magic value `0xFACEFEED`, sel `4'b0101`): **Result: clean DUT acked
  normally at latency 6; infected DUT never acked** (timed out at 101
  cycles, the same bound the golden testbench itself uses to flag a
  hang/DoS trojan) — a permanent FSM stall, exactly as documented.
- **Checkpoint 3** (reset recovery, after the hang: reset both DUTs,
  then an ordinary RMW write of `0xFACEFEEC`, sel `4'b0011`): **Result:
  both DUTs acked normally at latency 6,** confirming the trojan is a
  genuine trigger-gated FSM stall that clears on reset, not a bricked
  or permanently broken chip.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant required no debugging or
recalibration beyond the standard magic-value-collision check — the
offline PRNG replay (extended here to 260 words to cover this
testbench's full write-data sequence, rather than the 300-word figure
used for the cat1–cat3 submissions, since this design's golden
testbench issues 260 PRNG-sourced write words total: 128 full-sweep +
128 sel-sweep + 4 back-to-back) ruled out any collision before any RTL
was written, and the subsequent Eval1 run confirmed it empirically on
the first attempt. All three gates passed on the first complete
attempt.
