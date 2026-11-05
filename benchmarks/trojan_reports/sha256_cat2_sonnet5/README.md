# sha256 — cat2_sequential_counter_timebomb — top-module variant

The trojan lives in `sha256_core.v` — the top module. Unlike the cat1
variant (which targeted the `sha256_w_mem` submodule), this one needs the
core's own control FSM state directly, which has no cleaner home: the
completed-operation signal being counted, `CTRL_DONE`, only exists in
`sha256_core`'s `sha256_ctrl_fsm`/`sha256_ctrl_reg`, and pushing it down
into a submodule would mean exporting new ports just to carry it back up —
which would itself trip the structural-integrity gate. The harness's own
notes on category placement acknowledge this directly: a trojan can
legitimately live in the top module when the signal it needs isn't a
shared, multiply-instantiated submodule's own business.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (`sha256_core` chip area 65,934.5 µm²) |
| Eval1 | Icarus Verilog, full `tb_sha256_core.v` | PASS — all 76 test cases (228 total blocks, SHA-256 and SHA-224 modes) matched the independent reference |
| Eval2 | Icarus Verilog, infected `sha256_core` vs. an embedded clean reference, comparing `digest`/`digest_valid` through the real top-level ports across 233 total block completions | PASS — `TROJAN ACTIVATION CONFIRMED`: 231 ordinary, distinct single-block messages match the clean design bit-exactly; the 232nd completion diverges; a 233rd confirms the divergence stays latched rather than self-clearing |

**What it does:** a hidden counter (`op_cnt`) advances by one every
time the core's own FSM passes through its existing `CTRL_DONE` state —
riding along on a signal the design already has for its legitimate job,
not a brand-new always-toggling counter that would show up as obviously
extra switching activity. Once the counter reaches its terminal value, a
one-bit latch (`armed`) is set and never clears; from that completion
onward, every digest update flips the LSB of the `H0` chaining-value word
before it's written back, which — because SHA-256 feeds the chaining
value forward into every subsequent block of a multi-block message and
visibly changes the final digest — is permanently and completely
observable on the real `digest` output from that point on. No new
"trigger"/"trojan" names are used anywhere, and no comment in the infected
file describes the mechanism — `op_cnt` and `armed` read as
ordinary pass-counter/calibration-latch bookkeeping.

**Clean arming boundary, unlike the two `gemm` counter-based variants:**
the `gemm` cat2 and cat4 README's both had to document and fix a
same-call-divergence off-by-one, because a single logical GEMM "run" in
that design spans multiple internal clock edges that can observe a
latch set earlier in that same run. `sha256_core`'s `CTRL_DONE` state is
a single, discrete one-cycle-per-block pulse — there is no equivalent
multi-edge-per-call window here — so the counter's arming boundary landed
exactly where predicted on the first attempt: block 231 arms cleanly
(still uncorrupted, since the combinational digest-update logic reads the
pre-edge value of the latch), and block 232 is the first to diverge. No
testbench correction was needed for this one, confirmed by the Eval2 run
itself rather than assumed.

**Eval2 methodology note:** each of the 231 pre-arming blocks is distinct
(a fixed non-trivial filler pattern with the loop index carried in the low
32 bits), so this is 231 genuinely different messages driving the counter
up, not one message replayed — consistent with the trigger being purely a
completed-operation count and not tied to any particular message content,
which the two post-arming blocks (using entirely different, unrelated data
from each other and from the pre-arming set) also demonstrate: the
divergence shows up regardless of what data is being hashed, confirming
the trigger really is usage-count-based, not data-based.
