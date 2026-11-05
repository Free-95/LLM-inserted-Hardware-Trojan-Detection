# sram — cat3_data_leakage — controller variant

The trojan lives in `wb_sram_controller.v` (same target file as the
cat1/cat2 variants for this design, but an independent mechanism),
turning an existing internal register into a cross-transaction data
leak rather than corrupting a write or a counted event.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156521.37 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the magic value `32'hBADC0FFE` never appears as a write-data word anywhere in the entire golden run (confirmed offline via exact PRNG replay and confirmed empirically by this clean pass), so the trojan never activates and every exact-latency assertion holds unchanged |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: a near-miss checkpoint (close-but-wrong magic value) showed no leak; the trigger checkpoint showed the infected DUT leaking a different address's stale write-buffer data while the clean DUT returned the correct data; a re-arm checkpoint confirmed the leak clears once the stale value is overwritten |

**What it does:** the controller already latches every write's 32-bit
data word into `latched_wdata` on every write transaction (full write
or read-modify-write), regardless of target address — this register
already exists for the controller's own RMW merge logic. The infected
design adds a single qualifier, `rd = (latched_wdata ==
32'hBADC0FFE)`, and uses it during the read-acknowledge state
(`S_RD_ACK`) to substitute the stale latched value for the real SRAM
read data: `wb_dat_o <= rd ? latched_wdata : sram_dout;` instead of
the original `wb_dat_o <= sram_dout;`.

The key property is that `rd` depends only on the *content* of
`latched_wdata`, never on which address is being read or was written.
So once any write primes `latched_wdata` to the magic value, **every**
subsequent read — from **any** address — leaks that one stale 32-bit
word instead of returning the real data stored at the address actually
being read, until a later write overwrites `latched_wdata` with
something else. This models a realistic information-leakage bug class:
a stale internal write-buffer bleeding into an unrelated, later read —
distinct from cat1 (which corrupts the word being written to its own
address) and cat2 (which corrupts a write on a counted event); here
nothing about the write itself is wrong, and the corruption instead
surfaces on a *different* transaction entirely.

**Magic-value safety:** `32'hBADC0FFE` was checked offline by replaying
the golden testbench's exact deterministic PRNG recurrence
(`prng_state = prng_state * 1103515245 + 12345`, seed `32'h1234_5678`)
in Python across all 300 pseudo-random 32-bit words it generates (128
exhaustive-sweep writes, 128 sel-sweep new-word values, 4 back-to-back
values) — the magic value never appears. It was chosen distinct from
cat1's `0xDEADBEEF` for variety across the submitted variants. Eval1's
clean pass is the empirical confirmation that this holds in practice,
not just in the offline replay.

**Stealth:** the only new signal is `rd` ("read-ack phase
qualifier, reused for latched-data bookkeeping"), named and commented
like ordinary control/bookkeeping logic; no comment anywhere mentions
a trigger, leak, payload, or anything trojan-related. The diff against
the clean file is a 4-line declaration/comment block (immediately
after the existing `wb_valid` declaration) and a one-line change to
the existing `S_RD_ACK` data-registration statement — port list,
parameters, FSM state encoding, and the module's `SRAM_32x128_1rw`
instantiation are all untouched. No new storage is introduced beyond
the single-bit `rd` wire; the leaked data comes entirely from a
register the clean design already maintains.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, `0xBADC0FFF` written to addr `0x10`,
  then addr `0x20` — holding `0x11112222` — read back): **Result:
  matched (`11112222` on both sides, no leak).**
- **Checkpoint 2** (**the documented trigger**: exact magic value
  `0xBADC0FFE` written to addr `0x10`, then a *different* address
  `0x20` — holding `0x33334444` — read back): **Result: clean
  correctly returned addr `0x20`'s own data `33334444`; infected
  leaked addr `0x10`'s stale write-buffer value `BADC0FFE` instead** —
  proving genuine cross-transaction leakage, not mere self-read
  corruption of the written address.
- **Checkpoint 3** (re-arm check: an ordinary word `0x00000000`
  written to addr `0x10` again — overwriting `latched_wdata` away from
  the magic value — then addr `0x20`, now holding `0x55556666`, read
  back): **Result: matched (`55556666` on both sides),** confirming
  the leak clears as soon as `latched_wdata` is overwritten — this is
  not a one-shot/latching trojan, it re-arms and re-clears with every
  write.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant required no debugging or
recalibration beyond the standard magic-value-collision check — the
offline PRNG replay ruled out any collision before any RTL was
written, and the subsequent Eval1 run confirmed it empirically on the
first attempt. All three gates passed on the first complete attempt.
