# picorv32 — cat7_protocol_violation — single-file CPU core

Same single-file situation as the cat1–cat6 variants: `picorv32.v` has no
submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED` with the trigger constant physically present in the design |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program through the real top-level bus, with a per-cycle functional-equivalence monitor | PASS — `TROJAN ACTIVATION CONFIRMED`: `functional_divergence_count=0` (every write's address/data/strobe, and `trap`, bit-identical between infected and clean for the whole run); the triggering write is confirmed mislabeled with `mem_instr=1` instead of the correct `0` |

**Is cat7 applicable here, and what did it take to get right?** `picorv32`
has a genuine request/ready bus protocol (`mem_valid`/`mem_ready`) with
real rules an observer or arbiter could rely on, so cat7 is applicable —
but getting a *safe* violation took three attempts, each one informative,
documented here rather than smoothed over.

1. **First attempt: insert an extra phantom bus transaction** (an
   unrequested read to a fixed bogus address), the same shape as the
   `sha256` cat7 variant's extra completion pulse. This repeatedly
   corrupted real execution: direct tracing showed `picorv32`'s
   instruction-fetch pipeline keeps the bus almost constantly busy via
   tight prefetch overlap, so there is effectively no genuinely idle
   cycle to insert a transaction into without colliding with (and
   silently replacing) a real, simultaneously-starting fetch. Even after
   adding an explicit guard against the obvious request-pending flags
   (`mem_do_prefetch`/`mem_do_rinst`/`mem_do_rdata`/`mem_do_wdata`), the
   collision persisted because those flags can transition from 0 to 1 on
   the very same edge my override was evaluated against — the core's own
   "start a new transaction" decision and my "is it safe to insert mine"
   check are driven by state that updates on the identical clock edge,
   so checking the pre-edge value can't see what's about to happen. This
   path was abandoned after it reliably produced a trap partway through
   execution, confirmed by direct PC/state tracing, not assumed.
2. **Second attempt: mislabel an already-happening write's type**
   (`mem_instr`) instead of inserting anything new — a much lower-risk
   design, since `mem_instr` has zero internal feedback in this design
   (confirmed by grep: it's written in exactly one place and read back
   nowhere except debug/formal-verification-only code and the optional
   AXI wrapper's `arprot` signal). This avoided the collision risk
   entirely, but the override landed one cycle into the transaction
   rather than at its start, because the detection condition
   (`mem_valid && |mem_wstrb`) reads values that only become visible
   *after* the transaction has already begun, not the signal that
   actually causes it to begin.
3. **Final, working version**: keyed the override off `mem_do_wdata` —
   the existing signal that *causes* `mem_valid` to assert on the
   following edge — so the mislabel lands on the exact same edge the
   write transaction starts, matching the window a real bus observer
   would actually sample.

**What it does:** when a register-register `ADD` instruction's second
operand's low 16 bits equal a specific, chosen constant, a pending latch
arms. The very next real data write then has its `mem_instr` field
forced to `1` (claiming "this is an instruction fetch") instead of the
correct `0` — its address, data, write-strobe, and timing are completely
untouched. The qualifier/latch are named `bus_match`/`bus_pending`,
reading as ordinary calibration bookkeeping; no new "trigger"/"trojan"/
"phantom"/"mislabel" names are used anywhere in the file.

**Eval2 methodology note:** as with the cat6 variant, proving this is a
*pure* protocol violation (not disguised data corruption) requires
checking two things, not one: that `mem_instr` is wrong on the
trigger write (confirmed), and that every actual transaction's address,
data, write-strobe, and `trap` state stay bit-identical to the clean
core for the entire simulation (also confirmed, via the same per-cycle
functional-equivalence monitor technique used in the cat6 variant).
