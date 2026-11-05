# i2c — cat4_dos_hang — byte-controller variant

The trojan lives in `i2c_master_byte_ctrl.v` (same target file as the
cat1 and cat2 variants for this design, but an independent mechanism
touching a different part of the state machine), the mid-level
byte-protocol state machine instantiated once inside `i2c_master_top`.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 9904.4992 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run never writes data byte `0xE7`, so the design never triggers (if it had, the golden testbench's own `wait_tip_clear` polling task would itself have hung and timed out instead of completing) |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, polling the real top-level `i2c_master_top` Wishbone status register with a bounded poll count in place of an unbounded wait | PASS — `TROJAN ACTIVATION CONFIRMED`: two bracketing near-miss checkpoints (one byte below, one byte above the magic value) completed normally on both DUTs; the checkpoint at the exact magic byte showed the infected DUT's TIP status bit never clearing within the poll bound while the clean DUT completed normally |

**What it does:** a hidden 1-bit flag (`ld_flag`) is latched every time
the module's own pre-existing `(ld & write)` condition fires (the same
signals already used to gate a host byte-load), recording whether the
just-loaded data byte equaled the rare value `0xE7`. This flag is then
checked at exactly one point: the `ST_WRITE` state's normal
`(core_ack & cnt_done)` transition, which is the point where the
clean design always advances to `ST_ACK` (and eventually asserts
`cmd_ack`, clearing the host-visible `TIP` "transfer in progress"
status bit). When `ld_flag` is set, the state machine instead stays in
`ST_WRITE` and forces the internal I2C command to NOP — so `cmd_ack` is
never asserted again for that transaction, and `TIP` never clears. The
I2C bus itself is left idle (SCL/SDA simply stop toggling and return to
their released/pulled-high state — no bus-protocol violation, no stuck
clock line), but the Wishbone/software side of the core is wedged: any
driver that correctly waits for `TIP` to clear before issuing its next
command — exactly what this design's own golden testbench does via its
`wait_tip_clear` task — hangs indefinitely. This is a classic
denial-of-service trojan: no data is corrupted and the bus is left
physically clean, but the host-visible completion handshake silently
stops firing.

**Why this is a genuine fit for cat4 on this design:** the i2c core's
entire Wishbone interface contract rests on the host correctly polling
`TIP` (or waiting for the interrupt) before reusing the command
register — the core offers no other way to know a transaction is done.
A trojan that selectively breaks only that one handshake bit, for one
rare data value, while leaving the physical I2C bus in a fully valid
idle state, is a realistic and high-impact DoS: it would not be caught
by a bus-protocol analyzer or a bit-level bus monitor, only by a host
driver (or testbench) that happens to use that exact byte value and
then notices its own polling loop never returns.

**Stealth:** the only new signal is `ld_flag` ("load-phase tracking
flag"), named and commented like ordinary state-tracking bookkeeping;
no comment anywhere mentions a trigger, hang, denial-of-service, or
anything trojan-related. The diff against the clean file is a 1-line
register declaration, an 11-line latch `always` block (built entirely
from signals — `ld`, `write`, `din` — the module already computes for
its own byte-load logic), and a 7-line change to one branch of the
existing `ST_WRITE` case arm. The payload condition (`if (ld_flag)`)
sits inline inside state-machine branching a reviewer would expect to
see conditionals in anyway, rather than appearing as an obviously
out-of-place new block. Port list, parameters, and this module's
instantiation inside `i2c_master_top` are all untouched.

**Eval2 methodology:** a hang cannot be proven with an unbounded wait
(that would make the testbench itself appear to hang rather than
demonstrate the trojan). Instead, Eval2 uses the exact same
bounded-poll pattern the design's own golden testbench already uses for
ordinary busy-waiting (`wait_tip_clear`/`BUSY_TIMEOUT_POLLS`), with the
bound set generously above the handful of polls a real transaction ever
needs (confirmed directly: both near-miss checkpoints complete in well
under 50 polls). A poll count that reaches the bound without `TIP`
clearing is reported as a hang; one that clears early is reported as
normal completion. Each checkpoint starts from a fresh synchronous
reset (which also clears `ld_flag` and returns `c_state` to `ST_IDLE`
on the infected DUT, so a hung checkpoint doesn't contaminate the next
one):

- **Checkpoint 1** (write byte `0xE6`, one below the magic value):
  **Result: both infected and clean completed normally (no hang).**
- **Checkpoint 2** (write byte `0xE7`, **the documented trigger**):
  **Result: clean completed normally; infected `TIP` never cleared
  within 50000 polls, exactly as documented.**
- **Checkpoint 3** (write byte `0xE8`, one above the magic value):
  **Result: both infected and clean completed normally (no hang),**
  confirming the trigger is an exact single-value match rather than a
  threshold or range.

0 unexpected hangs and exactly 1 documented trigger confirmation across
all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant's state-machine change was
straightforward enough (a single `if` added to one existing branch,
reusing only signals already local to that one `always` block) that it
passed all three gates on the first complete attempt, with no
miscalibration bugs of the kind encountered in the cat2 and cat3
variants for this design. The one deliberate design choice worth
calling out: the infected branch forces `core_cmd <= I2C_CMD_NOP`
rather than leaving `core_cmd` unmodified, specifically so the bit
controller below it cleanly stops issuing further SCL/SDA transitions
and settles to bus-idle, rather than potentially re-issuing a stale
write command — keeping the denial-of-service purely a Wishbone-side
effect instead of also corrupting the physical bus. As with the cat3
submission for this design, the Eval2 testbench's embedded clean
reference hierarchy (`i2c_master_top_clean` / `i2c_master_byte_ctrl_clean`
/ `i2c_master_bit_ctrl_clean`) was generated programmatically, directly
from the untouched `clean_baseline/i2c/` source files, and the fully
assembled testbench was grepped to confirm zero occurrences of
`ld_flag` anywhere after the `// --- Clean Design ---` marker before
any Eval2 result was trusted.
