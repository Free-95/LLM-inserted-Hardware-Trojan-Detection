# picorv32 — cat6_watermark — single-file CPU core

Same single-file situation as the cat1–cat5 variants: `picorv32.v` has no
submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED` with the trigger constant physically present in the design |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program through the real top-level bus, with a **per-cycle functional-equivalence monitor** running for the entire simulation | PASS — `TROJAN ACTIVATION CONFIRMED`: `functional_divergence_count=0` for the whole run (every store, and `trap`, bit-identical between infected and clean on every single cycle); `trace_valid` pulses exactly once on the infected side with the correct watermark pattern, zero times on clean |

**Which port is genuinely spare, and which one I correctly ruled out
first:** `picorv32`'s `pcpi_valid`/`pcpi_insn`/`pcpi_rs1`/`pcpi_rs2` ports
looked like an obvious cat6 candidate at first glance — the golden
testbench instantiates the core with `ENABLE_PCPI(0)` and explicitly
leaves those ports unconnected. But tracing the actual logic shows
`localparam WITH_PCPI = ENABLE_PCPI || ENABLE_MUL || ENABLE_FAST_MUL ||
ENABLE_DIV`, and the golden testbench's real configuration has
`ENABLE_MUL(1)` and `ENABLE_DIV(1)` — meaning `pcpi_valid` *does*
legitimately pulse during normal operation, every time a multiply or
divide instruction is executed, via the internal MUL/DIV co-processor
units which are themselves implemented as built-in PCPI cores. Using
that port would have been a real functional-channel trojan mislabeled as
a benign watermark. The genuinely idle port, confirmed by direct code
inspection, is `trace_valid`/`trace_data`: every assignment that could
set `trace_valid <= 1` except the one this variant adds is wrapped in an
explicit `if (ENABLE_TRACE)` guard, and the golden testbench's actual
configuration is `ENABLE_TRACE(0)` — so in the real tested/deployed
configuration, `trace_valid` is provably always 0 and `trace_data` is
don't-care, with the testbench not even connecting those ports.

**What it does:** when a register-register `ADD` instruction's second
operand's low 16 bits equal a specific, chosen constant (the same narrow
`instr_add`-only targeting used throughout this set), `trace_valid`
pulses high for one cycle and `trace_data` is set to a fixed pattern
(`0xca110000`). Nothing else about that instruction's execution, or any
other instruction's, changes in any way. The qualifier wire is named
`wm_match`, reading as ordinary calibration matching logic; no new
"trigger"/"trojan"/"watermark" names are used anywhere.

**Why Eval2 for this category needed a different (stronger) proof
structure than every other variant in this set:** every other category
here is proven by checking that *some* observable differs between
infected and clean. cat6 needs the opposite proof too — that *nothing
else* differs — or the "watermark" claim is unverified at best and a
disguised data-corruption trojan at worst. This testbench runs a
dedicated functional-equivalence monitor every single clock cycle for
the entire simulation (not just at a few checkpoint reads), comparing
the full memory bus transaction and `trap` between the two cores, and
only declares success if that divergence count is exactly zero for the
whole run alongside the trace port firing as expected. A result where
the trace port differs but the functional monitor also shows even one
cycle of divergence would fail this check, by design.
