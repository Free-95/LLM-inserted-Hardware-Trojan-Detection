# i2c — cat6_benign_watermark — top-level variant

The trojan lives in `i2c_master_top.v` (same target file as the cat5
variant for this design, but an independent mechanism), specifically in
the debug command-register readback path.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 9990.832 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden testbench never writes the magic command word `8'h04` to CR (its CR writes are all real command-bit combinations — `0x90`, `0x10`, `0x20`, `0x28`, `0x40`, `0x41`, `0x50`, `0x01`) and never even reads the debug CR address, so the trigger never activates |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, checking the debug-CR readback **and** an explicit SCL bus-activity witness **and** the status register's TIP bit on both DUTs | PASS — `TROJAN ACTIVATION CONFIRMED`: ordinary command traffic and a near-miss pattern both read back identically on both DUTs; the documented trigger showed the infected DUT's debug-CR readback replaced with a fixed signature while SCL never toggled and TIP never asserted on either DUT — proving the watermark has zero effect on real I2C behavior |

**What it does — and why "benign":** every other variant submitted for
this design either corrupts data, hangs the host interface, or silently
mistunes a timing parameter. This one is different by design: it
embeds a fixed, hidden signature byte (`8'hC5`) that becomes readable
through the core's existing (but functionally inert, diagnostics-only)
debug command-register readback path — Wishbone address `3'b110`,
labeled `"Debug out control reg"` in the clean source itself, and never
used by any real driver (a real driver reads live status through `SR`
at address `3'b100` instead). The signature only appears after the host
writes the command register with exactly `8'h04` — setting *only* the
command register's own already-reserved bit (`cr[2]`), with every real
protocol bit (START, STOP, READ, WRITE, ACK, SL_CONT, IACK) left at
zero. The clean source itself documents this bit as reserved and shows
hardware already auto-clearing it the cycle after any write — so this
exact pattern carries no protocol meaning to begin with, and no real
I2C driver would ever write it in isolation. Critically, because no
real command bit is set, the write **cannot** start, continue, stop, or
otherwise disturb any I2C transaction: Eval2 explicitly confirms SCL
never transitions and `TIP` never asserts on either DUT across the
entire triggering checkpoint. This is a genuine "benign" trojan in the
IP-watermarking sense: a hidden, provable ownership signature that an
IP owner (or their own test harness) can read back on demand, embedded
in a way that cannot corrupt, hang, or otherwise interfere with the
core's real operation for any legitimate user.

**Stealth:** the only new signal is `cr_ld_echo` ("command-register
load echo"), named and commented like an ordinary bookkeeping mirror of
the command register's own load path — no comment anywhere mentions a
trigger, watermark, signature, or anything trojan-related. The diff
against the clean file is a 2-line register declaration/comment, a
one-line change to a single existing case arm inside the debug-readback
mux, and a 10-line `always` block that deliberately mirrors `cr`'s own
existing load-guard condition (`wb_wacc & core_en & (wb_adr_i ==
3'b100)`) verbatim, rather than introducing a new, differently-shaped
condition a reviewer might notice. Port list, parameters, and this
module's two sub-module instantiations are all untouched.

**Checkpoints:**
- **Checkpoint 1** (ordinary `START,WR` + `STOP` command traffic):
  **Result: debug-CR readback matches on both DUTs (`0x40`)** — the
  substitution mux is exercised through its normal pass-through path
  with no deviation.
- **Checkpoint 2** (`CR=0x04`, **the documented trigger**): **Result:
  infected debug-CR readback = `0xC5` (the signature) vs. clean = `0x00`
  (the real, already auto-cleared command-register value); SCL never
  toggled on either DUT (`bus_touched_inf=0`, `bus_touched_cln=0`) and
  `TIP` stayed `0` on both (`sr_tip_inf=00`, `sr_tip_cln=00`)** —
  confirming the watermark fired with provably zero effect on real I2C
  behavior.
- **Checkpoint 3** (`CR=0x05`, reserved bit + IACK — a different,
  nearby pattern): **Result: debug-CR readback matches on both DUTs
  (`0x00`)**, confirming the trigger is an exact single-value match,
  not "any write with the reserved bit set."

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** the magic command word (`8'h04`) and the choice
of readback address (the documented-but-unused debug CR path) were
selected specifically so that: (1) the golden testbench's own CR-write
vocabulary (all real command-bit combinations, confirmed by direct
inspection) could never collide with it, and (2) the trigger condition
could reuse `cr`'s own existing load-guard signals exactly, avoiding
any new hierarchical or timing-sensitive logic. Both properties held on
the first full attempt — no calibration-sweep or probe-based debugging
was needed before all three gates passed. As with the cat3/cat4/cat5
submissions for this design, the Eval2 testbench's embedded clean
reference hierarchy (`i2c_master_top_clean` / `i2c_master_byte_ctrl_clean`
/ `i2c_master_bit_ctrl_clean`) was generated programmatically, directly
from the untouched `clean_baseline/i2c/` source files, and the fully
assembled testbench was grepped to confirm zero occurrences of
`cr_ld_echo` anywhere after the `// --- Clean Design ---` marker before
any Eval2 result was trusted.
