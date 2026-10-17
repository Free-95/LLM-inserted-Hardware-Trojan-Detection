# arbiter (wb_arbiter_2m1s) — cat4_dos_hang — variant 0 

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (1021.0 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — all original checks pass |
| Eval2 | Icarus Verilog, infected vs. clean, sustained post-trigger window | PASS — `TROJAN ACTIVATION CONFIRMED`: pre-trigger traffic acked promptly on both designs; post-trigger, master 1's ordinary request is acked by the clean design but hangs forever on the infected design |

**What it does:** a sticky latch (`hold_latched`) is permanently set the
first time the currently-granted master issues any request to the trap
address `0x00000A00` (unreachable by golden traffic). Once latched, it
permanently disables the arbiter's lock-release condition — `lock` can
never deassert again, meaning arbitration itself is permanently frozen.
This isn't a one-cycle glitch: it's an irreversible denial-of-service that
persists for the rest of the simulation/operation, exactly matching the
cat4 ("Denial-of-Service / Hang") definition of forcing a busy/lock-style
signal to stay stuck, locking the state machine permanently.

**Three issues caught and fixed during development**:
1. The same implicit-1-bit-`wire` width bug as the earlier cat1 variant
   (`sel_addr_hold` truncated the 32-bit address comparison) — caught with
   a direct hierarchical probe before trusting Eval1.
2. My first Eval2 draft shared one `s_ack_i` line between the infected and
   clean DUT instances, incorrectly entangling their slave responses —
   rewritten with two fully independent per-DUT ack stubs.
3. Point-sampling the ack signal at one fixed cycle offset missed its
   one-cycle-wide pulse, producing false pre-trigger failures — rewritten
   to accumulate "ack seen anywhere in an N-cycle window" instead.

This variant required noticeably more iteration than the data/control-
corruption categories, since a permanent hang needs a genuinely different
Eval2 structure (a sustained post-trigger comparison window, not a single-
cycle value diff) — each of the three bugs above surfaced specifically
because of that structural difference.
