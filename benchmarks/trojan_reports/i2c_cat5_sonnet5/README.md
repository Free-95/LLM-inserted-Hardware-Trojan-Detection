# i2c — cat5_parametric_rare_value_corruption — top-level variant

The trojan lives in `i2c_master_top.v` (a new target file for this
design — the cat1/cat2/cat4 variants modified `i2c_master_byte_ctrl.v`
and cat3 modified `i2c_master_bit_ctrl.v`), specifically in the
Wishbone register-write path for the low byte of `PRER`, the 16-bit
clock-prescale register.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 9925.7696 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden testbench's own explicit register-sanity and prescaler-variation checks write `PRER_LO` = `0xFA`, `0xC8`, `0x04` and assert the read-back is unchanged — none is the magic value `0x5A`, so the trigger never activates and those assertions pass exactly as in the clean design |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, checking both a real Wishbone register read-back and a real measured SCL clock period on the top-level pin | PASS — `TROJAN ACTIVATION CONFIRMED`: a near-miss below and a near-miss above the magic value both read back unchanged on both DUTs; the checkpoint at the exact magic value showed the infected DUT's stored `PRER_LO` silently corrupted (confirmed by read-back) **and** a measurably different real SCL clock period on the physical `scl_pad_o` pin |

**What it does — and why it's "parametric", not a data-path trojan:**
every other variant submitted for this design corrupts a value that
flows through a *single transaction* (a data byte, a counted event, a
sampled bit). `PRER` is different: it is a genuine configuration
*parameter* of the core, wired directly into `i2c_master_bit_ctrl`'s
`clk_cnt` input, that sets the SCL clock-divider count for the entire
remaining lifetime of the core's operation, until the host reprograms
it again. A new combinational check, `lo_cal = (wb_dat_i == 8'h5a)`,
gates the one existing case arm that loads `PRER_LO`: when the host
writes exactly `0x5A`, the design silently stores `0x5B` (the written
byte XOR `0x01`) instead. Every other register (`PRER_HI`, `CTR`,
`TXR`, `SADR`) and every other `PRER_LO` value is loaded exactly as in
the clean design. Because the corrupted value feeds the real clock
divider, this is not a cosmetically-wrong-but-inert register: it
measurably changes the timing of every I2C transaction the core runs
afterward — a single rare configuration write silently and permanently
(until reprogrammed) mis-tunes the core's bus speed.

**Stealth:** the only new signal is `lo_cal` ("low-byte register-load
calibration check"), named and commented like ordinary write-path
bookkeeping; no comment anywhere mentions a trigger, corruption, or
anything trojan-related. The diff against the clean file is a 2-line
wire declaration/comment and a one-line change to a single existing
case arm inside the register-write `always` block — port list,
parameters, and this module's two sub-module instantiations are all
untouched. The payload sits inline inside a `case` statement a reviewer
would already expect conditional logic in, rather than appearing as an
obviously separate new block, and the trigger fires only on a register
write the host itself initiates — no hidden free-running counter or
cross-module/hierarchical reference is needed.

**Eval2 methodology — two independent top-level checks:** a
corrupted-but-unused configuration field would be a weak activation
proof (observable in a register dump, but never actually affecting
anything), so this submission checks the effect two ways, both purely
through real top-level ports of `i2c_master_top`:

1. **Register read-back** — write `PRER_LO`, then read it back over the
   same Wishbone interface. Bit-exact and immediate.
2. **Real SCL period measurement** — after programming the core and
   issuing one ordinary START+address-write+data-write+STOP
   transaction, the testbench times the real high-period of the
   `scl_pad_o` pin directly (no internal probing of either DUT) and
   compares the infected and clean DUTs' measured periods.

**Checkpoints:**
- **Checkpoint 1** (write `0xC8`, the design's own golden-testbench
  value): **Result: both infected and clean read back `0xC8`
  unchanged (match).**
- **Checkpoint 2** (write `0x5A`, **the documented trigger**):
  **Result: clean correctly stored/read back `0x5A`; infected silently
  stored `0x5B` instead (confirmed by read-back) — and the measured
  real SCL period differed: infected = 5060 ns vs. clean = 4830 ns,
  both DUTs programmed with the identical requested `PRER_LO=0x5A`.**
- **Checkpoint 3** (write `0x5B`, one above the magic value):
  **Result: both infected and clean read back `0x5B` unchanged
  (match),** confirming an exact single-value match rather than a
  range or threshold.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant's magic value (`0x5A`) and its
placement inside the existing register-write case statement were
chosen with the design's own golden-testbench PRER_LO values already
known from earlier work on this design (`0xFA`, `0xC8`, `0x04` — none
collide), so no calibration-sweep or probe-based debugging was needed
before all three gates passed on the first full attempt. As with the
cat3 and cat4 submissions for this design, the Eval2 testbench's
embedded clean reference hierarchy (`i2c_master_top_clean` /
`i2c_master_byte_ctrl_clean` / `i2c_master_bit_ctrl_clean`) was
generated programmatically, directly from the untouched
`clean_baseline/i2c/` source files, and the fully assembled testbench
was grepped to confirm zero occurrences of `lo_cal` anywhere after the
`// --- Clean Design ---` marker before any Eval2 result was trusted.
