# i2c — cat3_data_leakage — bit-controller variant

The trojan lives in `i2c_master_bit_ctrl.v`, the low-level bit-timing
state machine instantiated once inside `i2c_master_byte_ctrl`, which is
itself instantiated once inside `i2c_master_top`. This is a different
target file from both the cat1 and cat2 variants submitted for this
design (which both modified `i2c_master_byte_ctrl.v`), chosen for
diversity and because this module's own internal accumulator (`cnt`,
the SCL/SDA clock-divider counter) and its own address-snoop register
(`slave_adr`) gave a clean, self-contained fit for an information-leakage
mechanism without needing any new cross-module signal.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 9975.8176 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run only ever addresses the default SADR (0x10), which produces snooped `slave_adr` values of 0x20/0x21 during READ commands (confirmed by direct instrumented-probe tracing) — nowhere near the magic value 0x6b, so the trigger never activates |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `i2c_master_top` Wishbone/I2C interface | PASS — `TROJAN ACTIVATION CONFIRMED`: a near-miss at the golden/default address matched, the documented trigger (read transaction at the rare address) showed the leaked byte instead of the real slave data, and a near-miss write-only transaction at the same rare address (no READ command ever issued) also matched, proving the address match alone is not sufficient |

**What it does:** the bit-controller's SDA-sample register, `dout`
(which is shifted, one bit at a time, into the byte controller's RXR —
the host-visible Wishbone register a driver reads to get the last I2C
byte), normally always takes the real sampled SDA line value on every
rising edge of the filtered/synchronized SCL. When a new, purely
combinational condition holds — `cmd == I2C_CMD_READ` (the pre-existing
4'b1000 encoding) **and** `slave_adr == 8'h6b` — `dout` instead takes
bit 0 of `cnt`, the module's own free-running 16-bit clock-divider
counter (commented in the clean source as "clock divider counter
(synthesis)"), an internal accumulator with no legitimate path to any
host-visible register in the clean design. Every status and handshake
signal behaves identically to the clean design; only the data content of
the RXR byte read while the condition holds is affected.

`slave_adr` is an existing register the bit-controller already
maintains purely to support the design's own multi-master/slave-mode
logic: it passively shifts in any 8 bits observed on the bus immediately
after any START condition, regardless of which master is driving the
bus — including this core's own master-mode traffic. `8'h6b` is the
read-phase (RW=1) address byte for 7-bit slave address `0x35`
(`{0110101, 1} = 01101011 = 0x6b`), so the trigger fires only when the
host directs a READ at that one specific, rare I2C slave address.

**Why `slave_adr == 8'h6b` and not `8'h6a` (the write-phase byte for the
same address) — the calibration pitfall this variant required:** an
earlier attempt at this variant (not included in this submission)
matched on the *write-phase* address byte (`8'h6a`, RW=0) instead, on
the reasoning that the write-address snoop would still be latched when
the subsequent repeated-start READ command began. An instrumented probe
build (not part of this submission's files) showed this was wrong: the
byte controller's own state machine reuses `cmd == I2C_CMD_READ` not
just for the 8 real data-read bits, but also for the single-bit
host-ACK sample that follows *every* WRITE of a byte (address or data).
So `cmd == READ` momentarily true with `slave_adr` still `8'h6a`
corresponds only to those transient ACK-bit samples, never to the
actual 8-bit data read — by the time the real READ data bits are
clocked in, the repeated-start address byte has already updated
`slave_adr` to `8'h6b`. The first attempt at this design therefore
built and ran cleanly through all three gates but produced **zero**
leaked-byte mismatches in Eval2 (`clean=infected=0x77`), which was
caught precisely because the documented trigger never fired — not
treated as a pass. Matching on the read-phase byte `8'h6b` instead was
confirmed, via the same probe, to line up with the entire following
8-bit data read and its trailing ACK-bit sample (9 consecutive
SCL-rising-edge samples, all with `slave_adr == 8'h6b` and the trigger
asserted, for one read transaction at this address) — and that is the
version in this submission.

**Eval2 result, in detail:** with `PRER` fixed at `0x00C8` for this
testbench, `cnt` happens to equal the exact same value (`0x00c6`, an
even number) at every SCL-rising-edge sample within one read byte, so
in this specific run the leaked byte comes out as a deterministic
`0x00` rather than something that visibly varies bit-to-bit. This is
reported plainly rather than glossed over: it does not weaken the
activation result (RXR is provably driven from an internal accumulator
instead of the real bus line — `infected=0x00` vs `clean=0x77`, through
the real top-level WB interface, exactly as documented), but it does
mean this particular testbench's calibration happens to land on a
timing coincidence where the leaked value is currently constant. The
underlying mechanism still leaks a live internal signal on every
activation; a different clock-prescale value, a different number of
prior transactions (which shifts the counter's phase), or a downstream
consumer comparing successive reads at different points in the bus's
history would observe `cnt[0]` genuinely varying rather than staying at
one fixed value.

**Checkpoints (Eval2):**
- **Checkpoint 1** (SADR=0x10, matches the design's own golden
  testbench default): ordinary read transaction, no rare address ever
  snooped. **Result: matched (`0x3c` both sides).**
- **Checkpoint 2** (SADR=0x35, full write-then-repeated-start-read
  cycle, **the documented trigger**): the read-phase address snoop
  lands exactly on `8'h6b`. **Result: clean correctly read back
  `0x77`; infected leaked `0x00` (bit 0 of the internal clock-divider
  counter, sampled 8 times) instead of the real slave data.**
- **Checkpoint 3** (SADR=0x35 again, but write-only — no READ command
  is ever issued): proves the rare address match by itself, without the
  `cmd==READ` half of the condition, does nothing. **Result: matched
  (`0xc8` both sides — a status/debug register readback used here only
  as a sanity check, since no actual RXR read occurs in a write-only
  cycle).**

0 unexpected mismatches and exactly 1 documented trigger mismatch across
all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Stealth:** the only new signal is `samp_chk` ("sample-phase
qualifier"), named and commented like ordinary bit-sampling bookkeeping;
no comment anywhere mentions a trigger, leak, payload, or anything
trojan-related. The diff against the clean file is a 2-line wire
declaration/comment block and a one-line change to the existing
dout-generation `always` block — port list, parameters, and this
module's instantiation inside `i2c_master_byte_ctrl` are all untouched.
Both signals feeding the trigger (`cmd`, `slave_adr`) are pre-existing
internal signals the module already computes for its own slave-mode and
multi-master arbitration support, so the diff introduces no new
hierarchical or cross-module reference — avoiding the exact
synthesizability risk an earlier, discarded design idea for this
variant would have carried (an initial idea referenced the internal
counter of the bit-controller instance *from inside* the byte-controller
module via a hierarchical path, `bit_controller.cnt`; that was rejected
before any code was written, specifically because such a reference can
be rejected or silently mishandled by some synthesis flows, and because
it would have required touching the byte-controller's own source as
well).

**Bug caught and fixed during development:** as documented above, the
first working version of this variant matched the trigger on the
*write-phase* address byte instead of the read-phase byte, which
compiled and ran through Eval0/Eval1 cleanly but never actually
corrupted RXR in Eval2 (`documented_trigger_mismatches == 0`). This was
caught because the Eval2 result explicitly checks for the documented
mismatch pattern rather than simply checking "infected != clean
somewhere," so a trojan that silently fails to fire is reported as a
failure rather than a false pass. Root-caused via an instrumented probe
build that logged `slave_adr`/`cmd` on every SCL-rising edge and showed
the byte controller's ACK-bit sampling (which also uses `cmd==READ`)
was consuming the write-phase address match before the real data bits
ever arrived. Fixed by re-deriving the magic value from the read-phase
address byte instead, and re-verified with the same probe methodology
before re-running Eval2. The Eval2 testbench's embedded clean reference
hierarchy (`i2c_master_top_clean` / `i2c_master_byte_ctrl_clean` /
`i2c_master_bit_ctrl_clean`) was generated programmatically, directly
from the untouched `clean_baseline/i2c/` source files (never from any
infected working copy), and the fully assembled testbench was grepped
to confirm zero occurrences of `samp_chk` anywhere after the
`// --- Clean Design ---` marker before any Eval2 result was trusted —
applying the same lesson learned the hard way during the cat2 submission
for this design.
