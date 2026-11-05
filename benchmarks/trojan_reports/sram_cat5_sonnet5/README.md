# sram — cat5_parametric_rare_value_corruption — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1–cat4 variants for this design, but an independent mechanism),
corrupting the RMW merge result only when two pre-existing control
parameters — the target address and the byte-select pattern — both hit
specific values simultaneously, rather than reacting to a single rare
data word.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156433.78 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run's RMW sweep only ever targets word addresses 0–7, so the address half of the trigger's two-parameter AND condition is never satisfied, and the merge result is never corrupted |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: two independent near-miss checkpoints (address mismatch alone, sel-pattern mismatch alone) both matched; the checkpoint where both parameters matched simultaneously showed exactly the documented bit-8 corruption and nothing else |

**What it does:** the controller's RMW commit path already latches the
target word address (`latched_addr`) and byte-select pattern
(`latched_sel`) into registers it uses for its own bookkeeping (driving
the SRAM macro during the write-back cycle, and selecting byte lanes in
`merge_bytes`). The infected design adds a single qualifier,
`mg_param = (latched_addr == 7'h2A) & (latched_sel == 4'b1010)`, and
uses it in `S_RMW_MERGE` to conditionally flip bit 8 (`0x00000100`) of
the merged word before it is committed: `merged_word <= mg_param ?
(merge_bytes(...) ^ 32'h00000100) : merge_bytes(...)`. The
`merge_bytes` computation itself is completely unmodified on both
branches — only the final committed result is corrupted, and only when
*both* parameters match exactly. This is a "parametric" trojan in the
literal sense: the trigger is a rare combination of control parameters
(an address and a mode-select field) the design already carries,
rather than a rare value appearing in the data path itself (as in the
cat1 and cat3 variants) or an event count (cat2) or a permanent stall
(cat4).

**Why no PRNG/data-value calibration was needed for this variant:**
this design's own golden testbench runs its full 16-pattern
byte-select RMW sweep only at word addresses 0–7 (`for (i = 0; i < 8;
i = i + 1) ... old_word = expected_mem[i]; for (j = 0; j < 16; j = j +
1) ... wb_write(i * 4, new_word, sel_pattern, lat);`). Word address
`0x2A` (42) *is* written during the earlier exhaustive full-word sweep,
but a full-word write (`sel == 4'hF`) never enters the RMW merge path
at all, so it never reaches `S_RMW_MERGE` and `mg_param` is never
evaluated there for that address. The address half of the trigger
condition is therefore structurally unreachable in the golden run
regardless of which sel pattern is ever presented — a simple
address-range fact, confirmed directly by reading the testbench and
confirmed empirically by the clean Eval1 pass, with no offline PRNG
replay required (unlike the data-value-triggered cat1/cat3 variants
for this design).

**Stealth:** the only new signal is `mg_param` ("merge-lane parametric
qualifier, reused for RMW commit bookkeeping"), named and commented
like ordinary control/bookkeeping logic; no comment anywhere mentions
a trigger, corruption, parametric condition, or anything
trojan-related. The diff against the clean file is a 4-line
declaration/comment block (immediately after the existing `wb_valid`
declaration) and a 2-line change to the single `merged_word`
assignment inside the existing `S_RMW_MERGE` case arm — the
`merge_bytes` computation is reused completely unmodified on both
branches of the conditional. Port list, parameters, FSM state
encoding, and the module's `SRAM_32x128_1rw` instantiation are all
untouched. The trigger reuses two registers (`latched_addr`,
`latched_sel`) the controller already maintains, adding no new storage
beyond the single-bit `mg_param` wire.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, address mismatch: RMW write at word
  `0x2B`, one past the documented address, with the documented sel
  pattern `4'b1010`): **Result: infected and clean both read back
  `ab34ef78` (match, no corruption).**
- **Checkpoint 2** (near-miss, sel mismatch: RMW write at the
  documented word `0x2A` with a different sel pattern `4'b0101`
  instead of `4'b1010`): **Result: infected and clean both read back
  `22443355` (match, no corruption).**
- **Checkpoint 3** (**the documented trigger**: RMW write at word
  `0x2A` with sel exactly `4'b1010` — both parameters match
  simultaneously): **Result: clean correctly merged/stored
  `88669977`; infected corrupted it to `88669877` (merged word XOR
  `0x00000100`), exactly as documented.**

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant required no debugging or
recalibration — reading the golden testbench's RMW-sweep loop bounds
(addresses 0–7 only) was sufficient to pick a structurally-unreachable
address with no PRNG replay needed, and all three gates passed on the
first complete attempt.
