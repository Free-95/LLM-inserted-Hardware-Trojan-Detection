# picorv32 — cat5_parametric_rare_value_corruption — single-file CPU core

Same single-file situation as the cat1–cat4 variants: `picorv32.v` has no
submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED` with the trigger constant physically present in the design, confirming it never arose as a legitimate ALU operand anywhere in the real firmware's execution |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program through the real top-level memory-mapped bus | PASS — `TROJAN ACTIVATION CONFIRMED`: 2 ordinary ADDs plus 2 deliberate near-misses (a true single-bit flip of the magic value, and a value sharing only its upper 16 bits) match the clean core exactly; the documented trigger diverges exactly as predicted; a follow-up ADD afterward matches again (no latch-up) |

**How this differs structurally from the cat1 variant, per cat5's own
narrower definition:** cat1's trigger combined a *partial*-bit match (the
second operand's low 16 bits) with the existing, separately-decoded
`instr_add` flag via AND — two distinct conditions. cat5's definition is
specifically about a single operand, address, index, or counter equaling
one exact value, with nothing else combined in. This variant's trigger is
exactly that: `reg_op2 == 32'hc001d00d`, a single full 32-bit equality,
with **no** instruction-type qualifier at all. The qualifier wire is
named `val_match`, reading as ordinary calibration-value matching
logic; no new "trigger"/"trojan" names are introduced anywhere in the
file.

**An honest note on what "no instruction-type qualifier" actually means
in practice, worth being precise about rather than overselling:**
removing the `instr_add` AND-term technically makes the shared ALU case
branch's *entire* instruction family (`LUI`/`AUIPC`/`JAL`/`JALR`/`ADDI`/
`ADD`/`SUB`) eligible to trigger, not just reg-reg `ADD` as in the cat1
variant. In practice, though, only register-register `ADD`/`SUB` can ever
actually supply an arbitrary full 32-bit value as `reg_op2` — `ADDI`'s
operand comes from a 12-bit sign-extended immediate (range
±2047, nowhere near a chosen 32-bit constant), and `LUI`/`AUIPC`/`JAL`/
`JALR`'s second operands are similarly constrained by their own
encodings. So despite the broader *structural* condition, the real-world
reachable surface ends up being the same reg-reg `ADD`/`SUB` instructions
the cat1 variant targeted — the two variants differ in trigger
*mechanism* (single unqualified equality vs. combined partial-bit-and-flag
AND), which is the actual cat1/cat5 distinction, not in which
instructions can realistically be affected. I think it's more useful to
say this plainly than to imply a broader blast radius than the design's
own instruction encodings actually allow.

**Eval2 methodology note:** the near-miss set includes a true single-bit
flip of the magic constant (`0xc001d00c` as `rs2`, differing from the
trigger's `0xc001d00d` by exactly the LSB) and a value sharing only the
magic constant's upper 16 bits with its lower 16 bits cleared — both
confirmed bit-exact against the clean reference, demonstrating the match
is precisely the full 32-bit value documented, not an accidentally
partial or truncated comparison.
