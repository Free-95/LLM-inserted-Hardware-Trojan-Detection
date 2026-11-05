# spi — cat6_benign_watermark — controller variant

The trojan lives in `spi_top.v` (same target file as the spi design's
cat7 submission, but an independent mechanism), hiding a fixed, benign
ID signature behind a register address that falls completely outside
this core's documented register map.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of `spi_top.v`, `spi_clgen.v` and `spi_shift.v`, top-module chip area 16095.44 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_spi_top.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run never addresses byte 0x1C (the watermark's trigger offset), so every documented register access is bit-for-bit identical to the clean design |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `spi_top` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: two near-miss reads of real, documented registers both matched exactly; the read of the reserved offset returned the fixed watermark on the infected DUT only |

**What it does:** `spi_top`'s register-read mux decodes only 3 address
bits (`wb_adr_i[4:2]`) into 7 real registers — `SPI_RX_0..3` (shared
with `SPI_TX_0..3` on a write), `SPI_CTRL`, `SPI_DEVIDE`, and `SPI_SS`.
The 8th possible offset, `3'b111` (byte address `0x1C`), is not
assigned to anything in the original design and falls straight through
to the mux's `default` arm, returning `32'bx` (undefined). The infected
design adds exactly one new case arm for that offset:

```verilog
3'b111: wb_dat = 32'h53504936; // reserved offset, part-ID readback for bring-up bookkeeping
```

`0x53504936` is ASCII `"SPI6"`. Because the read mux already decodes
purely off `wb_adr_i` (the clean design's own existing behavior — it
is not additionally gated on `wb_cyc_i`/`wb_stb_i`/`wb_we_i`), a plain
read at this one reserved address surfaces the constant through
`wb_dat_o` exactly like reading any other register, with zero effect
on any of the 7 real, documented registers. This is the textbook
definition of a **benign** watermark trojan: a hidden, verifiable
ownership signature with no functional impact on the device's intended
operation, reachable only through a register address no documented
driver, specification, or the golden testbench ever uses — useful for
an IP vendor to later prove authorship of a suspect die.

**Why no calibration was needed for this variant:** this is a pure
address-space gap, not a data value that needs checking against the
testbench's random-number generator. Every register access in
`tb_spi_top.v` uses one of the 7 documented byte addresses (`0x0`,
`0x4`, `0x8`, `0xc`, `0x10`, `0x14`, `0x18`); byte address `0x1C` never
appears anywhere in the golden run — a fact confirmed directly by
reading every address literal the testbench issues, with no offline
PRNG replay required (unlike the data-value-triggered cat7 variant for
this same design).

**Stealth:** the payload is exactly one new line added to the
controller's existing, otherwise completely untouched register-read
mux, commented as a plausible "reserved offset, part-ID readback for
bring-up bookkeeping" — real hardware IP commonly does expose a
read-only part/revision ID at a reserved address, so this reads as an
entirely ordinary design choice. No comment anywhere mentions a
trigger, watermark, or anything trojan-related. There are no new
signals, no new registers, and no change to any existing register's
read or write behavior, the control logic, the address decode for the
7 real registers, the SPI shift logic (`spi_shift.v`), or the clock
generator (`spi_clgen.v`). This is the smallest diff of any variant
submitted across either design so far — a single line.

**Checkpoints (Eval2):**
- **Checkpoint 1** (near-miss, a real documented register: write then
  read back `SPI_SS`): **Result: infected and clean both correctly
  returned `000000ab` (match, no watermark).**
- **Checkpoint 2** (near-miss, another real documented register: write
  then read back `SPI_DIVIDE`): **Result: infected and clean both
  correctly returned `00000003` (match, no watermark),** confirming
  the trigger is specific to the unused offset and not a general
  address-decode break.
- **Checkpoint 3** (**the documented trigger**: read byte address
  `0x1C`, offset 7): **Result: infected DUT returned the fixed
  watermark `53504936` ("SPI6"); clean DUT returned its undefined
  default,** exactly as documented.

0 unexpected mismatches and exactly 1 documented trigger confirmation
across all three checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this variant required no debugging or
recalibration — the Eval2 harness mirrors the exact `#1;`-delay,
`while (~ack) @(posedge clk);` stimulus pattern this design's cat7
submission established as necessary for this core's ack-generation
timing, applied here from the start, and all three gates passed on the
first complete attempt (after one minor Verilog syntax fix: named
blocks are required around local `reg` declarations under
Verilog-2001, which Icarus enforces without a SystemVerilog flag).
