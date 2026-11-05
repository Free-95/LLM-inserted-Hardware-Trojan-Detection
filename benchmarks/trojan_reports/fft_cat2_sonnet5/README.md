# fft — cat2_sequential_counter_timebomb — submodule variant

The trojan lives in `cpx_mad.v` — the complex multiply-add unit. It is 
instantiated twice inside the single `butterfly_2point` core 
(`upper_wing`, `lower_wing`), so this edit reaches both live call sites.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (156,740.3 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` | PASS |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean, driven through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED` across 23 total FFT runs (20 random sweeps, a warm-up, the trigger, a post-trigger check), exactly 1 mismatch |

**What it does:** a saturating counter (`cnt`) counts discrete
occurrences of the module's own "A" operand equaling `0xFACE` (P=2⁻¹⁶,
unreachable by golden traffic). On the 3rd occurrence, bit 14 of the
imaginary half of the result is flipped.

## Why this one took real engineering, and the bug it caught
Getting a top-level FFT input vector to land the 3rd cumulative occurrence
specifically on the final pipeline stage — the only place a corruption
survives, since this is an in-place, multi-stage FFT where every RAM slot
gets rewritten by each of the 3 stages in turn — required actual
trial-and-error against the real design:

1. **Structural fact exploited:** any corruption written during stage 0 or
   stage 1 gets unconditionally overwritten by the next stage's own
   (uncorrupted) computation of that same slot. Only a corruption landing
   on stage 2 (the final stage) survives to `output_data`.
2. **First naive attempts failed**, not because the counter was broken, but
   because simple single-sample stimulus produced *multiple* coincidental 
   matches per run, consuming counts on non-final-stage occurrences before 
   the intended final-stage one could become the firing 3rd hit.
3. **A real bug was caught and fixed in the process**: the first working
   design used a one-cycle `mode_fire` pulse to apply the correction. This
   passed a submodule-level isolated test cleanly — but silently failed
   through the real top-level FSM, because `cpx_mad` streams a *new*
   `result` every single clock cycle regardless of which cycle the FSM
   actually samples (CORDIC settling means over a dozen cycles can pass
   between presenting an operand and the FSM reading the result). A
   one-cycle pulse gets overwritten by ordinary streaming traffic long
   before the FSM's capture point. This was invisible from the submodule
   test alone — comparing against a clean top-level reference is what
   caught it. Fixed by latching the correction (`hold`) for the full
   duration the triggering operand stays matched, so the payload survives
   until the FSM actually reads it.
4. **The final working sequence**: one warm-up run (`input_data[2]=0xFACE`)
   consumes exactly one count via a deliberately non-final-stage, harmless
   occurrence. A second, precisely solved vector
   (`input_data[4] = -1346`, i.e. `0xFABE0000`) then produces its own two
   internal occurrences, with the second landing exactly on the final FFT
   stage — found via a 2-point affine probe against the real
   `vedic_multiplier_q8_8` + CORDIC pipeline (two trial simulations, then
   solved algebraically and confirmed exact), not assumed closed-form math.

