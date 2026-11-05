# sram — cat7_protocol_violation — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1–cat6 variants for this design, but an independent mechanism),
corrupting the bus protocol itself rather than any data value: a
specific write-data value causes a spurious, unrequested second ack
pulse one cycle after the master has already dropped `wb_cyc_i`.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156518.86 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the magic value `32'hC0DE1337` never appears as any write's data word anywhere in the golden run, so the trojan's one-shot latch is never armed and every write's ack behavior is identical to the clean design |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench driving both DUTs from one shared, lockstepped stimulus bus through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: a near-miss write produced no spurious ack on either DUT; the trigger write produced exactly one spurious ack on the infected DUT — asserted while `wb_cyc_i` was already low — and none on the clean DUT; a follow-up ordinary write confirmed the violation does not persist |

**What it does:** the controller's existing single-cycle ack pulse for
a full-word write (`S_WR_ACK: wb_ack_o <= 1'b1; state <= S_IDLE;`) is
left completely untouched. The infected design adds a qualifier,
`proto = (latched_wdata == 32'hC0DE1337)`, and a one-shot register,
`ack_pipe`, armed at the same cycle the real ack fires:
`ack_pipe <= proto`. One clock cycle later — back in `S_IDLE`,
typically right after a well-behaved master has already dropped
`wb_cyc_i`/`wb_stb_i` since it only needs to hold them through the real
ack — the controller asserts `wb_ack_o` a **second** time,
unconditioned on `wb_cyc_i` or `wb_stb_i`:

```verilog
S_IDLE: begin
    if (ack_pipe) begin
        wb_ack_o <= 1'b1;
        ack_pipe <= 1'b0;
    end
    if (wb_valid) begin
        ... (unchanged) ...
```

This is a direct Wishbone B4 protocol violation — a slave must never
assert `ack_o` except in response to an active, addressed
`cyc_i`/`stb_i`-qualified transaction. A spurious post-transaction ack
can be misread by a pipelined master, arbiter, or bus-fabric bridge as
confirmation of a transaction that was never issued, silently
corrupting downstream transaction accounting without touching a single
data value anywhere in the design. This is distinct from every other
variant submitted for this design: cat1/cat3/cat5 corrupt data values,
cat2 corrupts a write on a counted event, cat4 denies service
permanently, cat6 substitutes data on an unused command shape — cat7
corrupts the handshake protocol itself while every data path stays
provably correct.

**Magic-value safety:** `32'hC0DE1337` was checked offline by
replaying the golden testbench's exact deterministic PRNG recurrence
(`prng_state = prng_state * 1103515245 + 12345`, seed `32'h1234_5678`)
in Python across all 260 pseudo-random 32-bit words it generates, plus
every fixed non-PRNG constant it ever writes (`0xB0B0B0B0`,
`0xE0E0E0E0`, `0xBAADF00D`, `0xC0FFEE00`, `0x11223344`) — the magic
value collides with none of them, and was chosen distinct from the
values already used in this design's cat1–cat6 submissions. Eval1's
clean pass is the empirical confirmation that this holds in practice.

**A testing note worth documenting honestly:** the first Eval2 attempt
used two independently-sequenced per-DUT write tasks (the same pattern
used successfully for every earlier variant on this design) and
reported `TROJAN DID NOT FIRE`. Direct signal-level debugging (tracing
`state`/`ack_pipe`/`wb_ack_o` cycle-by-cycle against a minimal
standalone instance) confirmed the RTL mechanism itself was firing
correctly; the miss was in the testbench. Because the phantom ack is a
single-cycle event tied to a specific clock edge relative to the
triggering write, sequencing the infected DUT's full write-and-settle
sequence to completion before even starting the clean DUT's write left
many clock cycles between the infected phantom pulse (already come and
gone) and the point where it was sampled. The fix was to drive both
DUTs from one shared, lockstepped stimulus bus so every cycle can be
compared directly — necessary specifically because this variant's
signature lives in handshake *timing*, not in a settled data value the
way cat1–cat6's do.

**Stealth:** the two new elements, `proto` ("post-commit settle
qualifier, reused for ack-pipe bookkeeping") and `ack_pipe`
("settle-pipe flag, reused for post-commit bookkeeping"), are named and
commented like ordinary pipeline/settle-timing bookkeeping — a
plausible artifact of a bus-turnaround or settle-delay design pattern;
no comment anywhere mentions a trigger, protocol violation, spurious
ack, or anything trojan-related. The diff against the clean file is a
4-line declaration/comment block, a one-line register declaration, a
one-line reset-value addition, a 4-line addition at the top of the
existing `S_IDLE` case arm (guarded by the new flag, placed before the
pre-existing `wb_valid`-gated logic, which is otherwise untouched), and
a one-line addition inside the existing `S_WR_ACK` case arm — port
list, parameters, FSM state encoding, and the module's
`SRAM_32x128_1rw` instantiation are all untouched. No data path,
address decode, or memory-access logic is touched anywhere.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, ordinary full-word write, data !=
  magic value): **Result: both DUTs acked normally at the same
  latency with 0 ack pulses observed in the 8 cycles after
  `wb_cyc_i`/`wb_stb_i` dropped (no protocol violation).**
- **Checkpoint 2** (**the documented trigger**: full-word write with
  the exact magic value `0xC0DE1337`): **Result: clean DUT showed 0
  ack pulses after `wb_cyc_i`/`wb_stb_i` dropped; infected DUT showed
  exactly 1 — asserted while `wb_cyc_i` was already low** — the
  documented protocol violation, exactly as specified.
- **Checkpoint 3** (one-shot/recovery: an ordinary write issued
  immediately after the trigger): **Result: both DUTs acked normally
  with 0 further spurious pulses,** confirming the violation is a
  one-shot per triggering write, not a persistent fault.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** the magic-value collision check followed the
same offline-PRNG-replay methodology established for this design's
earlier variants and passed Eval1 on the first attempt. Eval2 required
one iteration to fix a testbench timing bug (documented above) before
correctly observing the trojan's effect — the RTL itself worked
correctly from the first implementation, verified directly via
signal-level debugging before the testbench fix was made.
