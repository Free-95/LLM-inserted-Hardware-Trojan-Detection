# i2c — cat2_sequential_counter_timebomb — byte-controller variant

The trojan lives in `i2c_master_byte_ctrl.v` (same target file as the
earlier cat1 variant for this design, but an independent mechanism), the
mid-level byte-protocol state machine instantiated once inside
`i2c_master_top`.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 10222.3 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run produces only ~46 total `(ld & write)` load events, far short of the magic count 220, so the design never triggers |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `i2c_master_top` Wishbone/I2C interface | PASS — `TROJAN ACTIVATION CONFIRMED`: two bracketing near-miss checkpoints (below and above the magic count) matched exactly; the one checkpoint landing exactly on the magic count showed exactly the documented +XOR 0x01 corruption and nothing else |

**What it does:** a hidden 8-bit counter (`svc_cnt`) increments on every
occurrence of the module's own existing `(ld & write)` condition — the
same signals the module already uses to gate a host byte-load, so no new
triggering condition is introduced, only a tally of an existing one. When
the counter equals the rare value `220` (i.e. on the 221st such load event
since the last reset), the byte being loaded on that one cycle is
corrupted: `sr <= din ^ 8'h01` instead of `sr <= din`. Every status and
handshake signal behaves identically to the clean design; only the data
value of the one byte-load that happens to coincide with the 221st event
is wrong, and the counter keeps counting afterward rather than resetting
or re-arming, so the corruption fires exactly once and never recurs
(confirmed directly in Eval2, see below).

**Why reuse `(ld & write)` as both the cat1 trigger input and the cat2
counting input:** this follows the diversification guidance to vary the
trigger *mechanism*, not necessarily the module or signals touched — a
realistic attacker reusing the same innocuous-looking load-gating
condition for a data-match trojan in one variant and a count-based
time-bomb in another is exactly the kind of low-footprint, hard-to-spot
pattern this dataset is meant to capture. The two variants' payloads are
independent: this file's counter and comparator (`svc_cnt`, `sel`)
are a separate addition from the cat1 variant's `sel`/data-match logic
built for that earlier submission.

**Stealth:** the only new signals are `svc_cnt` ("service-cycle counter")
and `sel` ("write-path load calibration select"), named and commented
like ordinary calibration/housekeeping logic; no comment anywhere
mentions a trigger, payload, count, or anything trojan-related. The diff
against the clean file is a 2-line declaration block, a 12-line counter
`always` block + comparator `assign` (entirely new logic, touching no
existing line), and a one-line change to the existing load `always`
block — port list, parameters, and the `i2c_master_bit_ctrl` instantiation
are all untouched.

**Eval2 methodology and calibration (the hard part of this variant):**
unlike a data-value trigger, a count-based trigger has to be driven to an
*exact* number of real hardware events through the top-level interface,
and this design's own bus-arbitration logic generates a variable number
of extra retry pulses per WB command depending on recent bus history —
so a naive "3 events per write-then-readback cycle" arithmetic model
(which would have been correct for an idealized, retry-free bus) turned
out to be wrong in practice, and an early attempt at this variant (not
included in this submission) mis-landed the corruption on an
address-write sub-event instead of the intended data-write sub-event,
corrupting the slave-memory address instead of the data and producing
undefined read-back values.

The methodology that actually worked: an instrumented probe build (not
part of this submission's files) established that a minimal filler
transaction (`START,WR` + `byte,WR+STOP`, no address/read-back phase)
produces an exact, zero-variance 4 `(ld & write)` pulses every single
time, regardless of how many fillers precede it. The design's own
synchronous reset also resets `svc_cnt` to 0, so each of Eval2's three
checkpoints starts from a clean, reproducible baseline (reset → N
deterministic fillers → one verified write-then-read-back cycle), with N
swept and probed beforehand to confirm, per checkpoint, *which* WB-command
phase (if any) of the verified cycle would land on `svc_cnt==220`:

- **Checkpoint 1** (52 fillers): probe-confirmed no phase of the verified
  cycle touches 220 at all — ordinary transaction, must match. **Result:
  matched (`0x3c` both sides).**
- **Checkpoint 2** (54 fillers, **the documented trigger**): probe-confirmed
  the verified cycle's DATA-WRITE phase lands exactly on `svc_cnt==220`.
  **Result: clean correctly stored/read back `0x77`; infected corrupted it
  to `0x76` (written byte XOR `0x01`), exactly as documented.**
- **Checkpoint 3** (56 fillers): probe-confirmed `svc_cnt==220` is crossed
  inside the (unverified) filler loop itself, so every phase of the
  following verified cycle is safely past it — proving the trigger does
  not stay latched or recur. **Result: matched (`0x91` both sides).**

0 unexpected mismatches and exactly 1 documented trigger mismatch across
all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Bug caught and fixed during development:** the embedded "clean"
reference hierarchy for Eval2 was initially generated (by an automated
renaming step) from the already-infected working copy of
`i2c_master_byte_ctrl.v` instead of from the true, pristine clean-baseline
file — so the first full Eval2 run was silently comparing the infected
design against a *second*, differently-thresholded copy of itself rather
than against a real clean reference. This was caught because the
"clean" side's read-back was itself wrong on an unrelated checkpoint,
which should be structurally impossible for a genuine clean reference;
tracing it back showed `sel`/`svc_cnt` present in the embedded clean
module source. Fixed by regenerating the embedded clean hierarchy
directly from the untouched `clean_baseline/i2c/` source files, and
verified by grepping the assembled testbench to confirm zero occurrences
of `sel`/`svc_cnt` anywhere after the `// --- Clean Design ---`
marker before accepting any Eval2 result.
