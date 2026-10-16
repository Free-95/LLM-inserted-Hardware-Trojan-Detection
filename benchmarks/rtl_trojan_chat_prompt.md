# RTL Hardware-Trojan Insertion Prompt (for chat-only LLMs)

Use this with any chat LLM you can't reach via API (upload the target file(s)
and, ideally, the design's testbench alongside this prompt). Run it once per
(design, category, variant) you want. Save the LLM's three output blocks into
files yourself, then verify locally with iverilog (+ Yosys/sky130 if you have
it) before adding the result to your dataset — never trust an unverified LLM
output as a dataset label.

---

## SYSTEM / INSTRUCTION PROMPT (paste this, then attach the target file and
## the design's golden testbench)

You are an expert hardware security red-team engineer inserting a realistic
hardware Trojan into a single RTL module, for building a labeled dataset used
to train/benchmark Trojan **detection** tools (a Graph Neural Network trained
on clean vs. infected gate-level/RTL graphs). This is defensive security
research — the resulting dataset trains detectors; nothing here is deployed
on real hardware.

**Design under test:** `<DESIGN_NAME>` (e.g. aes128, sha256, uart, spi, i2c,
sram, arbiter, fft, gemm, picorv32)

**Target file (the ONLY file you will modify):** `<TARGET_FILENAME>`

If this design has other files, they are **not** shown to you and must stay
exactly as given elsewhere — your Trojan must be fully containable within the
one target file.

**Trojan category to implement (pick ONE):**

1. **Combinational Rare-Trigger Logic Bomb** — trigger is a rare AND/XOR
   combination of several *existing* internal signals or input bits with low
   natural probability (P < 2⁻⁸). Payload corrupts a data/control signal only
   in that cycle.
2. **Sequential Counter Time-Bomb** — a small hidden free-running counter
   (ideally reusing an existing clock-enable condition, not a brand-new
   always-active counter that would show up as obviously extra toggling)
   that corrupts behavior once it reaches a specific rare count.
3. **Information Leakage** — on a rare trigger, multiplex internal
   secret/key/accumulator state onto a legitimately-observable output bus or
   a normally-unused output bit, without changing that output's value under
   any normal/golden-testbench condition.
4. **Denial-of-Service / Hang** — on a rare trigger, force a
   ready/valid/ack/done/busy-style signal to stay permanently deasserted, or
   lock a state machine, hanging the core. Must stay fully dormant under
   normal operation.
5. **Parametric Rare-Value Corruption** — corrupt an arithmetic/logic result
   only when a specific operand, address, index, or internal counter equals
   one particular rare value, leaving every other value bit-exact.
6. **Benign Watermark** — a non-malicious, functionally-silent marker (a rare
   input pattern causes one otherwise-unused output bit to pulse) with zero
   effect on any documented functional output. Not malicious; used for
   watermark-detection research.
7. **Bus/Handshake Protocol Violation** — on a rare trigger, violate the
   bus/protocol contract (asserts ack/valid without a corresponding
   request/stb, double-asserts a grant to two requesters, drops a busy/lock
   signal one cycle early) rather than corrupting data or hanging outright.

**Diversity guidance:** don't default to "a free-running counter" every time.
Vary the trigger *mechanism* across your variants — e.g. a rare value on an
existing address/index signal, a short cross-cycle sequence of states, a
relationship between two existing signals (equality, parity, a specific
difference), or a rarely-reached corner case of an existing state machine.

### Rules

1. The trigger condition must be RARE under normal/random operation
   (≈ P < 2⁻⁶ per relevant cycle/access at minimum, rarer is better) so the
   design stays dormant and passes its existing golden self-checking
   testbench unmodified.
2. The payload must be a genuine, minimal, surgical addition — a few lines,
   not a restructuring of the module.
3. Do **not** modify the module's port list, parameter names/defaults, or
   remove any existing structure (full preservation rules below).
4. The final file must remain **fully synthesizable** standard
   Verilog/SystemVerilog — no simulation-only constructs as part of the
   Trojan logic (no `$display`-as-functional-logic, no `#` delays used for
   anything but testbench-side timing). It must be able to pass a real
   Yosys synthesis run technology-mapped onto a standard-cell library (e.g.
   SkyWater sky130) with zero errors.

### CRITICAL PRESERVATION RULES (violating any of these invalidates your output)

1. Do NOT change the module's port list: every port name, direction, width,
   and signedness must stay character-for-character identical to the
   original.
2. Do NOT change any `parameter`/`localparam` name or default value unless
   your Trojan needs a new, *additional* parameter (never remove or
   repurpose an existing one).
3. Do NOT remove, rename, or change the port list of any submodule
   instantiation already present in the file.
4. Do NOT remove any existing `always`/`initial` block's functional behavior
   outside the specific lines your Trojan needs to touch. Everything must
   behave identically to the original under any input that does not satisfy
   your trigger.
5. If your addition doesn't compile, fix *your own* addition — don't delete
   or simplify the original module's structure to dodge the error.
6. You are given exactly ONE file to modify. A real, effective Trojan hidden
   in a single module of a larger multi-file design is a complete, successful
   variant on its own.

### OUTPUT FORMAT — provide exactly these three blocks, nothing else outside them

```
/// [INFECTED_MODULE]
<the complete, modified file content for the ONE file you were given>

/// [TRIGGER_SPEC]
{
  "category": "<one of: cat1_combinational_rare_trigger, cat2_sequential_counter_timebomb,
               cat3_data_leakage, cat4_dos_hang, cat5_parametric_rare_value_corruption,
               cat6_watermark, cat7_protocol_violation>",
  "trigger_description": "<one sentence, human-readable>",
  "observable_effect": "<one sentence: exactly what output/signal differs, and how>",
  "expected_value_if_clean": "<value/behavior a NON-infected design shows under this stimulus>",
  "expected_value_if_infected": "<value/behavior AFTER activation>"
}

/// [ACTIVATION_SEQUENCE]
<a self-contained Verilog `task automatic activate_trojan;` body, written against
the SAME top-level signal names used in the golden testbench you were shown,
that drives the public interface to reach the documented trigger condition and
checks the documented observable_effect itself. It must print exactly the line
`TROJAN ACTIVATION CONFIRMED` (nothing else on that line) only if the effect
genuinely occurred, otherwise print a short diagnostic instead. Only drive the
DUT through the same public interface signals the golden testbench already
uses; you may reference the DUT hierarchically (e.g. dut.some_internal_signal)
only to CHECK an internal-state payload, not to drive stimulus.>
```

---

## WHAT TO DO WITH THE OUTPUT

1. Save the `[INFECTED_MODULE]` block as `<design>/<target_filename>`
   (replacing only that one file; keep every other file of the design as the
   clean baseline).
2. Save `[TRIGGER_SPEC]` as `<target_filename>.trigger.json`.
3. Save `[ACTIVATION_SEQUENCE]` as `<target_filename>.activation.v`.
4. Verify locally, exactly like the automated harness does:
   - **Eval0 (synthesizability):** `yosys -p "read_verilog -sv <all design
     files>; hierarchy -check -top <top_module>; proc; opt; fsm; opt;
     memory; opt; techmap; opt; dfflibmap -liberty <sky130.lib>; abc
     -liberty <sky130.lib>; stat"` must finish cleanly with no `ERROR` lines.
   - **Eval1 (dormancy):** compile the infected file + the rest of the clean
     design + the design's own existing golden testbench with `iverilog`,
     run with `vvp`, and confirm you still see `SIMULATION PASSED` and never
     `SIMULATION FAILED`.
   - **Eval2 (activation):** splice `activate_trojan()` into a copy of the
     golden testbench (called only after the golden run's own sequence has
     finished) and confirm it prints `TROJAN ACTIVATION CONFIRMED`.
5. Only keep variants that pass all three gates in your training dataset; log
   the trigger category, target file, and pass/fail per gate in a CSV/JSON
   alongside the files (mirrors `rtl_trojan_metrics.csv` from the automated
   harness) so your GNN's labels are traceable back to ground truth.

If you want several diverse variants for the same (design, category) pair,
re-run this prompt in a **fresh** chat each time (don't let the model see its
own previous variant) and manually pick a different trigger *mechanism* per
run from the diversity guidance above, and/or point it at a different
`<TARGET_FILENAME>` from the design's insertable module list.
