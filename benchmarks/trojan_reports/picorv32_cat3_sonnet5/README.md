# picorv32 — cat3_data_leakage — single-file CPU core

Same single-file situation as the cat1/cat2 variants: `picorv32.v` has no
submodule split, so the top module is necessarily the target.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog, full `testbench.v` running real compiled RV32IM firmware | PASS — `SIMULATION PASSED` with the trigger constant physically present in the design, confirming it never arose as a legitimate store address anywhere in the real firmware's execution |
| Eval2 | Icarus Verilog, infected `picorv32` vs. an embedded clean reference, each with its own private memory, running an identical hand-assembled RV32I program (6 word stores) through the real top-level memory-mapped bus | PASS — `TROJAN ACTIVATION CONFIRMED`: 4 ordinary/near-miss stores match the clean core exactly; the documented trigger store diverges exactly as predicted, with the leaked value directly verified to equal the program counter at that instruction |

**What it does:** when a word-store (`SW`) instruction's base address
register has a specific, chosen value in its low 16 bits, the data
actually written to memory is replaced with the current program counter
(`reg_pc`) instead of the correct source-register value. `picorv32` has
no cryptographic "key" the way `sha256` does, so — same reasoning as the
`sha256` cat3 variant, applied to this design's own internal state — the
leaked value is genuine internal control-flow state that a real CPU
should never place directly into a store's data payload: knowing exactly
what instruction address executed at a given moment is itself sensitive
information in real systems (this is the same category of leak defeated
by ASLR, and the same shape of concern as cache-timing/Spectre-style
control-flow disclosure, just expressed here as a direct RTL-level
trojan rather than a microarchitectural side channel). The qualifier wire
is named `addr_match`, reading as ordinary address-calibration
matching logic; grepped against the unmodified clean file, this variant
introduces zero occurrences of "trigger" or any other suspicious term —
it doesn't even reference the existing `decoder_trigger` signal the
cat1/cat2 variants used, since the store-data-mux logic it hooks into
doesn't need it.

**A real bug caught before it ever reached Eval1, worth flagging because
it's specific to this design's memory-protection behavior:** my first
choice of magic constant (`16'hc0de`) is *not word-aligned* — its binary
representation ends in `10`, not `00`. Since `CATCH_MISALIGN=1` in this
configuration, no legitimate, non-faulting word-store instruction could
ever actually reach that exact address pattern, which would have made
the resulting "trojan" structurally unexercisable by any real program —
technically dormant, but not a meaningful latent threat, since nothing
could ever trip it without also trapping first. Caught by inspection
before running any gates, and fixed by switching to `16'hdec0` (ends in
`00`, word-aligned) — worth watching for in the real LLM-generated batch,
since picking an address-based trigger value without checking alignment
against a design's own misalignment-trap behavior is an easy mistake to
make and one that would silently produce an unrealistic (if technically
"passing") trojan.

**Eval2 methodology note:** the ordinary/near-miss set includes stores to
addresses exactly one word below and one word above the magic value
(`0x3000debc` and `0x3000dec4`, vs. the trigger's `0x3000dec0`), both
confirmed bit-exact against the clean reference, demonstrating the match
is precisely the documented 16-bit value and not an accidentally wide or
off-by-a-word comparison. The testbench models memory sparsely (a small
code array plus individually-named registers for each of the six store
targets the program actually uses) rather than a flat array across the
full `0x3000_xxxx` address range, since the program's data addresses are
deliberately placed far from its own ~130-byte code region — informed
directly by the self-modifying-code bug documented in the cat2 variant's
README, avoided here from the start rather than discovered by tracing.
