# sram — cat6_benign_watermark — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1–cat5 variants for this design, but an independent mechanism),
hiding a fixed, benign ID signature behind a read command pattern no
legitimate bus master in this design's normal usage ever produces.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156455.05 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden testbench's single `wb_read` task hardcodes `wb_sel_i = 4'hF` for every read it ever issues, so the watermark's trigger pattern (`sel == 4'b0000`) never occurs and every read returns the real stored data unchanged |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: an ordinary read (`sel=4'hF`) and a partial-but-nonzero-sel read (`sel=4'b0001`) both returned correct, matching data on both DUTs; the read issued with `sel=4'b0000` returned the fixed watermark constant on the infected DUT while the clean DUT returned the correct stored data |

**What it does:** the controller already latches the byte-select
pattern presented on every transaction into `latched_sel` — including
during reads, where `sel` has no effect on the clean design's behavior
at all (a read always returns the full 32-bit word regardless of which
sel bits are set). The infected design adds a single qualifier,
`id = (latched_sel == 4'b0000)`, and uses it in the read-ack state
to substitute a fixed constant for the real read data: `wb_dat_o <=
id ? 32'h43415436 : sram_dout;` (`0x43415436` is ASCII `"CAT6"`).
Because no conventional 32-bit Wishbone read ever drives `sel` to
all-zero — masters conventionally set `sel=4'hF` for a full-word
access — this watermark is reachable only through a deliberately
out-of-band read command pattern. It never corrupts, delays, or
otherwise affects any ordinary read (`sel=4'hF`) or any write (which
never evaluates `id` at all): this is the textbook definition of a
**benign** watermark trojan — a hidden, verifiable ownership signature
with zero functional impact on the device's intended operation, useful
for an IP vendor to later prove authorship of a suspect die by issuing
this exact unused command and checking for the signature.

**Why no PRNG/data-value calibration was needed for this variant:**
the golden testbench's `wb_read` task (used for every single read in
the entire run — the 128-word sweep, boundary reads, sel-sweep
readbacks, back-to-back reads, the post-abort recovery read, and the
err-check read) hardcodes `wb_sel_i = 4'hF` unconditionally. A read
with `sel=4'b0000` is therefore structurally unreachable in the golden
run — a simple fact confirmed directly by reading the testbench's task
body, with no offline PRNG replay required (unlike the data-value- or
counter-triggered cat1–cat3 variants for this design).

**Stealth:** the only new signal is `id` ("read-phase lane
qualifier, reused for ID-tag bookkeeping"), named and commented like
ordinary control/bookkeeping logic; no comment anywhere mentions a
trigger, watermark, signature, or anything trojan-related. The diff
against the clean file is a 4-line declaration/comment block
(immediately after the existing `wb_valid` declaration) and a one-line
change to the existing `S_RD_ACK` data-registration statement — port
list, parameters, FSM state encoding, and the module's
`SRAM_32x128_1rw` instantiation are all untouched. The trigger reuses
a register (`latched_sel`) the controller already maintains for its
own RMW bookkeeping, adding no new storage beyond the single-bit
`id` wire, and the payload is a hardcoded constant rather than any
additional state.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, ordinary read, `sel=4'hF` — the pattern
  every real read in the golden testbench uses): **Result: infected
  and clean both correctly returned `11112222` (match, no
  watermark).**
- **Checkpoint 2** (near-miss, partial nonzero sel `4'b0001` — not the
  documented all-zero pattern): **Result: infected and clean both
  correctly returned `33334444` (match, no watermark),** proving the
  trigger requires the exact all-zero pattern, not merely "sel !=
  4'hF".
- **Checkpoint 3** (**the documented trigger**: read with `sel =
  4'b0000`): **Result: clean correctly returned the stored data
  `55556666`; infected returned the fixed watermark `43415436`
  instead,** exactly as documented.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant required no debugging or
recalibration — reading the golden testbench's `wb_read` task to
confirm it always hardcodes `sel=4'hF` was sufficient to pick a
structurally-unreachable trigger pattern with no PRNG replay needed,
and all three gates passed on the first complete attempt.
