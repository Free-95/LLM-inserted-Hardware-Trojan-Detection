# i2c — cat1_combinational_rare_trigger — byte-controller variant

The trojan lives in `i2c_master_byte_ctrl.v`, the mid-level byte-protocol
state machine instantiated once inside `i2c_master_top` (the design's top
module, per `DESIGN_REGISTRY`), and itself instantiating `i2c_master_bit_ctrl`
underneath it.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files (`i2c_master_top.v`, `i2c_master_byte_ctrl.v`, `i2c_master_bit_ctrl.v`), top-module chip area 9904.5 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`, all of its checks (full write/read/repeated-start/invalid-address-NACK sequence, bus-busy, randomized burst write+read-back, prescaler sweep, interrupt-enable, multi-master arbitration contention) succeeded with the infected file in place |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `i2c_master_top` Wishbone/I2C interface | PASS — `TROJAN ACTIVATION CONFIRMED`: 6 ordinary/near-miss transactions (including two deliberate near-misses differing from the magic value by a single bit) all matched exactly between the infected and clean design; the one documented trigger transaction showed exactly the documented +XOR 0x01 corruption and nothing else ever differed |

**What it does:** when the host writes the byte `0xBA` to the transmit
register (`TXR`, which this module sees as its `din` input) and issues a
WRITE command, the exact cycle the byte-controller's internal shift register
is loaded (`ld` asserted while `write` is asserted) is a rare coincidence of
three already-existing signals: an 8-bit data-value match on `din` combined
with the existing `ld` and `write` control bits (P ≈ 2⁻⁸ for a uniformly
distributed data byte, matching the cat1 definition's P<2⁻⁸ threshold).  On
that cycle, the shift register is loaded with `din ^ 8'h01` instead of
`din` — the low bit of the byte about to go out is silently flipped before
it ever reaches the I2C bus. Every status and handshake signal (`cmd_ack`,
`i2c_busy`, `ack_out`, the bit-counter, the whole state machine) behaves
identically to the clean design; only the transmitted data byte is wrong.
A host that writes `0xBA` to a peripheral over I2C silently has `0xBB`
physically sent on the wire instead — a classic cat1 data-corruption payload,
not a protocol or availability violation.

**Why this target file, not the top module or the bit-controller:** the
byte-controller owns the one architectural point (`sr <= din` on `ld`) where
a full host-supplied data byte is captured from the Wishbone side before
being bit-serialized onto the physical I2C pins by the bit-controller below
it — exactly the kind of shared, reused mid-hierarchy module (instantiated
by both master-1 and master-2 of a multi-master system, if more than one
`i2c_master_top` is instantiated) that a real attacker would prefer over the
top module itself, per the harness's own guidance.

**Stealth:** the only new signal is `sel` ("write-path load calibration
select"), named and commented like an ordinary feature; no comment
mentions a trigger, payload, or anything trojan-related. The diff against
the clean file is four lines: one new `wire` declaration, one `assign`, and
a one-line change to the existing load `always` block — port list,
parameters, and the `i2c_master_bit_ctrl` instantiation are all untouched.

**Eval2 methodology note:** because the trojan's effect is a data-value
corruption of a byte driven out of the design across a bit-serial I2C
transaction (not a value sitting on a parallel bus), proving it at the
top level meant reproducing a miniature version of the golden testbench's
own WB-master + I2C-slave plumbing twice — once per DUT, on two fully
independent physical buses — rather than probing an internal signal
directly. Both sides are driven by bit-for-bit identical Wishbone command
sequences; the only thing compared is what a Wishbone read of `RXR`
returns after each write is immediately read back from the shared I2C
slave model's memory. Two deliberate near-miss stimuli (`0xBB`, `0x3A` —
each one bit away from the magic value `0xBA`) were included specifically
to rule out the trigger being accidentally broader than documented; both
came back as exact matches, confirming the comparator is bit-exact on the
full byte, not just "close enough."

**No bugs caught during development for this variant** — unlike the FFT
cat7 variant (which needed a non-degenerate-stimulus fix after a magic
value recurred at multiple internal points), this i2c variant's trigger is
anchored to the module's own `din`/`write`/`ld` ports with no internal
replay path, so a single, deliberately distinctive magic byte (`0xBA`,
verified beforehand against every literal byte value the golden testbench
and its seeded PRNG actually use: `0x00, 0x01, 0x04, 0x10, 0x20, 0x21,
0x28, 0x40, 0x41, 0x50, 0x5A, 0x80, 0x90, 0xA5, 0xC0, 0xC8, 0xCD, 0xFA`
plus the three PRNG-seeded burst-test bytes `0xCD, 0x83, 0x70`) was
sufficient on the first attempt, confirmed by both Eval1 (no accidental
fire anywhere in ~3,000,000 time units of real traffic) and Eval2's
near-miss checks.
