# fft — cat1_combinational_rare_trigger — submodule variant

The trojan lives in `rca_16bit.v` — the shared 16-bit adder/subtractor —
not the top module. It's instantiated 4 times inside every `cpx_mad`
complex multiply-add unit, itself instantiated twice inside the single
`butterfly_2point` core, so this one low-level edit reaches 8 live call
sites across the FFT pipeline's arithmetic datapath.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (156,720.3 µm²) |
| Eval1 | Icarus Verilog, full `tb_fft_8point.sv` (16 golden FFT vectors, reset recovery, timing margin, saturation stress) | PASS |
| Eval2 | Icarus Verilog, infected `fft_8point` vs. clean `fft_8point_clean`, driven through the real top-level interface | PASS — `TROJAN ACTIVATION CONFIRMED`, `output_data` corrupted only on the documented top-level input vector, across 32 full FFT runs (30 random sweeps + a 1-LSB near-miss + the trigger + a post-trigger check) |

**What it does:** when both adder operands exactly equal `A=0xDEAD` and
`B=0xBEEF` inside `rca_16bit` (P=2⁻³² per instance), the sum output is
XORed with `0x4000` — large enough to be unambiguous against the FFT
testbench's own ±64 Q8.8 LSB tolerance.

**How the top-level trigger vector was found:**
reaching an exact internal adder operand pair from the outside, through
an FFT's CORDIC/multiplier datapath, isn't generally solvable by inspection.
I exploited one structural fact (the very first butterfly each run always
uses twiddle index k=0, and the bit-reversed RAM load means
`input_data[0]`/`input_data[4]` feed that butterfly completely unchanged by
any arithmetic) to make the `A` operand directly settable — but my first
assumption that `k=0` gives an exact identity twiddle (`W=1.0+0.0j`) was
wrong. A direct simulation probe showed this core's CORDIC actually settles
to `W=(255,1)` in Q8.8 for `k=0` — a genuine 1-LSB rounding artifact I
discovered empirically, not something I could have derived by assuming
ideal math. Given that measured, fixed `W`, I found the required `B`
operand (`input_data[4]`'s real part = `0xBEAE`) by an exhaustive 16-bit
sweep against the real `vedic_multiplier_q8_8` + `rca_16bit` logic — not
analytic inversion — confirming it lands on exactly `0xBEEF` after the
multiply. Setting `input_data[0]=0xDEAD0000` and `input_data[4]=0xBEAE0000`
(all other samples zero) reaches the trojan purely through ordinary,
externally-driven FFT inputs, no internal signal forcing involved.

**Tooling note on Eval0:** `fft_8point.sv`'s SystemVerilog 2D packed-array
ports aren't parsed by Yosys 0.33 frontend; `sv2v` (a standard open-source 
flattener) bridges only that one synthesis-check step. The delivered 
`rca_16bit.v` and the rest of the design are untouched.
