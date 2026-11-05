# sram — cat2_sequential_counter_timebomb — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1 variant for this design, but an independent mechanism), reusing
the same full-word-write decode path cat1 corrupted on a data match,
this time corrupting it on an event count instead.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156744.08 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run produces exactly 144 full-word-write decode events (confirmed directly via an instrumented probe build), far short of the magic count 200, so the design never triggers |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: two bracketing near-miss checkpoints (counts 199 and 201) matched exactly; the checkpoint at the exact magic count (200) showed exactly the documented +XOR 1 corruption and nothing else |

**What it does:** a hidden 8-bit counter (`svc_cnt`) increments on
every existing full-word-write decode event — the same condition
(`state==S_IDLE & wb_valid & wb_we_i & wb_sel_i==4'hF`) the controller
already uses to route into its `S_WR_WAIT` state, so no new triggering
condition is introduced, only a tally of an existing one. When the
counter equals the rare value `200` (i.e. on the 201st such event since
the last reset), the word being committed to the SRAM macro on that one
write is corrupted: `sram_din <= wb_dat_i ^ 32'h00000001` instead of
`sram_din <= wb_dat_i`. Every status and ack signal behaves identically
to the clean design; only the data value of the one write that happens
to coincide with the 201st event is wrong, and the counter keeps
counting afterward rather than resetting or re-arming — it would fire
again at count 456 if the design ran that long (8-bit counter wraps and
reaches 200 again after 256 more events), and is fully inactive at
every other count in between (confirmed directly in Eval2, see below).

**Why this design needed no probe-based calibration, unlike the
earlier i2c cat2 submission:** the i2c designs' own bus-arbitration
retry logic made "pulses per command" non-constant, which required an
instrumented probe and careful filler/checkpoint sweeps to hit an exact
magic count reliably. This controller's FSM has no such variance: a
full-word write always produces exactly one decode event of the
trigger's counting condition, with no possibility of extra or missing
pulses. A plain count of filler writes (199, 200, 201) therefore lands
on the magic count exactly, with no calibration sweep required — the
golden-testbench event count (144, confirmed via one instrumented probe
run to pick a safely-clear magic value) was the only piece of empirical
groundwork this variant needed.

**Stealth:** the only new signals are `svc_cnt` ("service-cycle
counter") and `csel` ("full-word load calibration select"), named
and commented like ordinary calibration/housekeeping logic; no comment
anywhere mentions a trigger, payload, count, or anything
trojan-related. The diff against the clean file is a 4-line
declaration/comment block, a 3-line addition to one existing FSM
transition arm (reusing the exact decode condition the design already
computes to route into the full-write state — no new condition is
introduced, just a counter riding along with it), and a one-line change
to the existing full-write `sram_din` assignment — port list,
parameters, and the module's `SRAM_32x128_1rw` instantiation are all
untouched.

**Checkpoints (Eval2):**
- **Checkpoint 1** (199 filler full-word writes + 1 verified write,
  `svc_cnt==199` at the check): **Result: matched
  (`11112222` both sides).**
- **Checkpoint 2** (200 filler full-word writes + 1 verified write,
  `svc_cnt==200` at the check, **the documented trigger**): **Result:
  clean correctly stored/read back `33334444`; infected corrupted it to
  `33334445` (written word XOR 1), exactly as documented.**
- **Checkpoint 3** (201 filler full-word writes + 1 verified write,
  `svc_cnt==201` at the check): **Result: matched (`55556666` both
  sides),** confirming the trigger is an exact single-count match, not
  a threshold that stays armed past it.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** aside from the one instrumented probe run used
to confirm the golden testbench's exact full-word-write event count
(144, well clear of the chosen magic value 200), this variant required
no debugging or recalibration — the simpler, retry-free FSM of this
design made the counter's behavior fully deterministic by construction,
and all three gates passed on the first complete attempt.
