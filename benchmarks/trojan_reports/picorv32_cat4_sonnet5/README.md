# picorv32 — cat4_denial_of_service_hang — single-file CPU core

Same single-file situation as the cat1/cat2/cat3 variants: `picorv32.v`
has no submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED` with the trigger constant physically present in the design, confirming it never arose as a legitimate reg-reg ADD operand anywhere in the real firmware's execution |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program through the real top-level memory-mapped bus | PASS — `TROJAN ACTIVATION CONFIRMED`: 2 ordinary pre-trigger stores match the clean core exactly; all 3 post-trigger stores (including the trigger instruction's own immediately-following store) never execute at all on the infected core, while the clean core executes every one of them correctly |

**Is cat4 applicable here, and how?** `picorv32` has no single `ready`/
`busy`-style handshake output port the way `sha256_core` does — its real
top-level control surface is the `mem_valid`/`mem_ready` bus handshake
plus an internal `cpu_state` register that drives it. This variant
targets `cpu_state` directly: once armed, the main state register is
gated from updating on every subsequent cycle, so the core genuinely stops
fetching, decoding, or issuing bus transactions ever again — the actual
literal meaning of "hangs the core" from cat4's definition, just expressed
through this design's own real control structure rather than a dedicated
status pin.

**What it does:** when a register-register `ADD` instruction's second
operand's low 16 bits equal a specific, chosen constant (the same narrow
`instr_add`-only targeting used by the cat1/cat2 variants), a hold latch
arms. Once armed, a single statement placed as the very last assignment
in the CPU's main state-update block — `if (hold) cpu_state <=
cpu_state;` — overrides whatever the rest of that cycle's logic decided,
holding the state register at its current value forever (Verilog's
"last non-blocking assignment in a block wins" rule makes this override
authoritative over everything earlier in the same always block, including
the FSM's own case statement and its misalignment-trap handling). The
qualifier/latch are named `hold_match`/`hold`, reading as ordinary
calibration-hold bookkeeping; no new "trigger"/"trojan"/"hang"/"freeze"/
"dos"/"denial" names are used anywhere, and the implementation comment
describing it was deliberately kept at the mechanism-neutral level (it
originally used the word "freezes" while documenting the hold latch during
development, which was reworded before finalizing — the shipped file
carries no comment describing what the hold actually does to the design's
behavior, consistent with every other variant in this set).

**A real, directly-measured timing subtlety — the same class of issue
documented in the `sha256` and `gemm` cat2/cat4 variants, here specific to
picorv32's multi-cycle-per-instruction pipeline:** my first version of
the Eval2 test assumed the triggering `ADD` instruction's own result would
still reach memory via the very next `SW` instruction, since arming
"shouldn't" affect the instruction already in flight. Running it showed
otherwise: the `SW` immediately following the trigger `ADD` also never
executed. The explanation is that `hold` arms during the `ADD`'s own
multi-cycle processing (picorv32 takes several clock cycles per
instruction, unlike a single-cycle design), and by the time the core would
next transition through `cpu_state_fetch` for the following `SW`, the hold
is already active and blocks that transition from ever completing. I
verified this directly via Eval2's own output rather than assuming it, and
corrected the test's expectations (and its pass criterion) to match what
was actually measured.

**Eval2 methodology note:** rather than probing internal FSM state
directly, the hang is demonstrated the way cat4's definition implies it
should be — purely through the core's real top-level bus activity. Three
post-trigger store instructions are programmed; on the clean core all
three execute and write their correct, predictable values; on the
infected core all three memory locations remain at their untouched
initial value of zero, directly proving those instructions never ran.
