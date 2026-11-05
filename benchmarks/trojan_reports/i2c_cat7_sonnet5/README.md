# i2c — cat7_protocol_violation — bit-controller variant

The trojan lives in `i2c_master_bit_ctrl.v` (same target file as the
cat3 variant for this design, but an independent mechanism reusing the
same existing `slave_adr` signal for a very different purpose), in the
WRITE-bit generation sub-state machine (`wr_a`/`wr_b`/`wr_c`/`wr_d`).

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of all three design files, top-module chip area 9930.7744 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_i2c_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden testbench only ever addresses SADR=0x10, producing snooped `slave_adr` values 0x20/0x21 (confirmed in the cat3 submission's probe work for this design) — never the odd magic value 0x99 — so the trigger never activates |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, counting real SDA-transitions-while-SCL-high purely on the top-level bus pins | PASS — `TROJAN ACTIVATION CONFIRMED`: ordinary traffic and a near-miss odd address both show an identical transition count on both DUTs (all legitimate START/STOP conditions); the documented trigger showed the infected DUT with three extra illegal transitions the clean DUT did not have, for the identical stimulus |

**What it does — and why this is a genuine protocol violation, not a
data-corruption trojan:** every other variant submitted for this
design corrupts a value, hangs a handshake, mistunes a parameter, or
embeds a signature — all effects confined to this core's own
registers. This one is different in kind: it corrupts the **physical
waveform** on the shared I2C bus itself, in a way any *other* device
listening on the bus would misinterpret, regardless of what this core's
own internal bookkeeping thinks happened.

During a WRITE bit, the clean design's bit-level state machine holds
SCL high for one sub-state, `wr_c` — the clean source's own comment
says `"keep SCL high"`, and the clean design is careful enough to use
this exact window for its own self-check against multi-master
arbitration loss (`sda_chk`). The trojan adds one combinational check,
`byte_cal = (slave_adr == 8'h99)`, reusing `slave_adr` — the
bit-controller's own existing passive bus-address-snoop register,
already used by the cat3 submission for this design for an unrelated
purpose — and when it holds, `wr_c` drives SDA to the **complement** of
the bit actually being transmitted instead of the real bit, while SCL
stays high. Per the I2C specification, any SDA transition while SCL is
high, outside of a deliberate START or STOP sequence, is **itself**
indistinguishable from a (repeated) START (1→0) or STOP (0→1)
condition to every other device on the bus — regardless of what this
core's own shift register ends up storing for its own purposes. A
trojan that injects this kind of glitch can desynchronize or confuse
any other master or slave sharing the bus, entirely independent of
whatever data value this core itself believes it sent or received.

`8'h99` was chosen deliberately as an **odd** byte: the low (R/W) bit
of any snooped *write-phase* address byte is always 0, so `8'h99` can
only ever arise from a *read-phase* address snoop (R/W=1) — specifically
7-bit address `0x4C`, giving `{0x4C,1}=8'h99`. This testbench therefore
deliberately addresses a slave in the READ direction, then — at the raw
Wishbone command-register level, which any real driver is free to do —
issues a WRITE command immediately afterward instead of a READ, so the
just-snooped `slave_adr=0x99` is still active while a real WRITE data
byte's bits are transmitted.

**Stealth:** the only new signal is `byte_cal` ("write-phase
calibration check"), named and commented like ordinary hold-time
bookkeeping; no comment anywhere mentions a trigger, violation, or
anything trojan-related. The diff against the clean file is a 1-line
wire declaration, a 2-line `assign` statement reusing the pre-existing
`slave_adr` signal, and a one-character-deep change to a single
existing case arm (`din` → `byte_cal ? ~din : din`) — port list,
parameters, and this module's instantiation inside
`i2c_master_byte_ctrl` are all untouched. The payload sits inside
exactly the one state (`wr_c`) the clean design already singles out as
special — it is the state that enables the design's own arbitration-
loss self-check — so a reviewer skimming the state machine would see
conditional logic in a place conditional logic is already expected,
not an obviously out-of-place addition.

**Eval2 methodology — why this has to be a count comparison, not a
presence check:** a naive "did SDA ever transition while SCL was high"
check is useless here, because a *legitimate* START or STOP condition
is, structurally, exactly that kind of transition — that is precisely
what makes this trojan's glitch dangerous: it is indistinguishable from
a real START/STOP to anything downstream. The first attempt at this
Eval2 testbench used a bare presence flag and immediately (and
correctly) flagged *both* DUTs as "violating" on ordinary traffic,
because every real transaction's own START and STOP conditions tripped
it. The testbench in this submission instead counts every such
transition across an entire checkpoint and compares the infected and
clean DUT's counts for the *identical* stimulus: equal counts means no
extra glitch (all transitions are the stimulus's own legitimate
START/STOP conditions); a higher count on the infected side means
extra, illegal transitions were injected. A second finding during
development: because `slave_adr` (not a per-bit counter) gates the
condition, it holds for the *entire* triggered byte, so every bit of
that byte independently glitches during its own `wr_c` window — not
just one bit — which is why the trigger checkpoint shows **three**
extra transitions (not exactly one) for an 8-bit byte: only the bits
whose complemented value actually differs from the line's
already-settled level produce an observable edge once the bus's own
settling delay is accounted for.

**Checkpoints:**
- **Checkpoint 1** (ordinary write-then-repeated-start-read cycle at
  the design's own golden SADR=0x10): **Result: identical
  SDA-while-SCL-high transition count on both DUTs (4 — all legitimate
  START/STOP conditions, no extra glitch).**
- **Checkpoint 2** (address `0x4C` in the READ direction, snooping
  `slave_adr=0x99`, then a WRITE command, **the documented trigger**):
  **Result: infected=7, clean=4 — three extra illegal transitions on
  the infected DUT's SDA pin while SCL was held high, exactly the
  spec-illegal mid-bit glitch documented above.**
- **Checkpoint 3** (address `0x4D` in the READ direction, snooping a
  different odd value `slave_adr=0x9B`): **Result: identical
  SDA-while-SCL-high transition count on both DUTs (4),** confirming an
  exact single-value match rather than "any odd snooped address."

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** the count-based re-design described above was
the one real debugging step this variant required — the initial
presence-based Eval2 check failed on *both* DUTs for ordinary traffic,
which immediately made clear the check itself (not the trojan) was
wrong, since the clean reference DUT cannot possibly contain a trojan.
Re-deriving the check as a stimulus-controlled count comparison (rather
than a bare "did it ever happen" flag) resolved this and is, on
reflection, the only correct way to test for an illegal-transition-type
protocol violation when the stimulus itself legitimately contains the
same class of transition (START/STOP). As with the cat3/cat4/cat5/cat6
submissions for this design, the Eval2 testbench's embedded clean
reference hierarchy (`i2c_master_top_clean` / `i2c_master_byte_ctrl_clean`
/ `i2c_master_bit_ctrl_clean`) was generated programmatically, directly
from the untouched `clean_baseline/i2c/` source files, and the fully
assembled testbench was grepped to confirm zero occurrences of
`byte_cal` anywhere after the `// --- Clean Design ---` marker before
any Eval2 result was trusted.
