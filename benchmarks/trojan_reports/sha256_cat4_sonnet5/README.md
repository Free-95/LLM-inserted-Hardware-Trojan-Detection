# sha256 — cat4_denial_of_service_hang — top-module variant, genuine handshake hang

The trojan lives in `sha256_core.v` — the top module, since the real
`ready`/busy handshake this trojan hangs is the core's own top-level port.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total blocks, SHA-256 and SHA-224 modes) matched the independent reference |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, watching the real top-level `ready` handshake on each side independently | PASS — `TROJAN ACTIVATION CONFIRMED`: the "abc" block and two deliberate near-misses complete normally with matching digests on both sides; the documented trigger block makes the infected side's `ready` never reassert while the clean side completes normally in its usual bounded latency |

**A genuine hang, not an adaptation this time:** the earlier `gemm` cat4
variant had to adapt the category, since that design has no
ready/valid/ack/done/busy port at all — the closest honest equivalent was
a permanent datapath freeze. `sha256_core` is a different situation
entirely: it has a real `ready` output that is specifically a busy/done
handshake signal (deasserted while a block is being processed, reasserted
on completion), exactly matching cat4's canonical definition. This
variant forces that real signal to never reassert, which is a direct,
literal implementation of the category rather than an adapted one.

**What it does:** when the message block's word at bits `[95:64]`
(word index 13 of 16) equals a specific, never-otherwise-occurring
32-bit constant, a sticky latch (`hold`) is set on the
first round cycle of that block's processing and never clears. From then
on, the round counter (`t_ctr_reg`) is prevented from ever advancing, so
the control FSM can never reach the round count that triggers the
transition out of `CTRL_ROUNDS` — the core is stuck in that state
permanently, `ready` stays deasserted forever, and no block, including
every subsequent one, ever completes again. The compression datapath
keeps running on stale operands every cycle (consuming power, doing no
useful work), which is the real-world signature of this class of hang.
The qualifier wire and latch are named `blk_match` and `hold`,
reading as ordinary calibration bookkeeping; no new "trigger"/"trojan"/
"hang" names are used anywhere, and no comment describes the mechanism.

**A genuine testbench race I hit and fixed during development, worth
documenting because it's a realistic pitfall for the LLM-generated batch
too:** my first version of the arming condition read the raw `init` pulse
directly inside the same clocked `always` block, at the exact simulation
time the testbench's `run_block` task deasserts it (`tb_init = 0;`,
immediately after `@(posedge clk);`, both with blocking assignments — the
same style the design's own golden testbench uses throughout). This is a
textbook same-timestep Verilog scheduling race between a testbench's
blocking assignment and a DUT's synchronous always block reacting to the
same clock edge: direct hierarchical probing showed `init` correctly
settling to 1 well before the edge, yet the arm check still silently
never fired, because the testbench's `init = 0` and the DUT's own
evaluation of that edge were both scheduled in the same "active" region
with no guaranteed relative order. The rest of the design never hits this
problem because its own `init`-handling logic lives in a separate
*combinational* block whose outputs settle a full cycle ahead of the
edge, not in a value read directly at the coincident edge. Fixed by
re-expressing the arm condition in terms of a signal that is stable for
a full clock cycle instead of a single coincident pulse:
`(sha256_ctrl_reg == CTRL_ROUNDS) && (t_ctr_reg == 6'h0)`, i.e. "the first
round cycle of processing," which has no same-edge write to race against.
I also found and fixed a second, unrelated bug in my own Eval2
testbench's wait-for-completion task itself (an inverted condition that
incorrectly flagged the *clean* side as timed out) while chasing this
down — both are documented here rather than silently smoothed over,
since a from-scratch LLM run attempting a handshake-based hang on this
exact architecture could plausibly hit either one.

**Eval2 methodology note:** each side's `ready` handshake is tracked with
its own independent timeout counter rather than a single shared wait, so
the test actually distinguishes "infected hung, clean fine" from "both
hung" or "neither hung" — the correct, specific signature of a one-sided
denial of service, not inferred indirectly from a digest mismatch.
