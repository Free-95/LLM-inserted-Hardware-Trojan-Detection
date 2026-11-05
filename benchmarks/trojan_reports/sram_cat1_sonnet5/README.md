# sram — cat1_combinational_rare_trigger — controller variant

The trojan lives in `wb_sram_controller.v`, the Wishbone-to-SRAM-macro
controller, in the combinational macro-bus control block that drives
the memory array on a full-word write.

| Gate  | Tool                                | Result |
|-------|--------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib (real sky130A PDK) | PASS — exit 0, 0 `ERROR` lines, full technology mapping of both design files, top-module chip area 156463.8112 µm² |
| Eval1 | Icarus Verilog 12.0, full `tb_wb_sram_controller.v` (unmodified golden testbench) | PASS — `SIMULATION PASSED`; the golden run's 260 PRNG-generated words (exhaustive 128-word sweep + 16-pattern byte-select sweep + back-to-back) plus 5 explicit literal words never include the magic value, so the design never triggers and every exact-latency assertion passes unchanged |
| Eval2 | Icarus Verilog 12.0, standalone dual-DUT activation testbench, comparing read-back values through the real top-level `wb_sram_controller` Wishbone interface | PASS — `TROJAN ACTIVATION CONFIRMED`: ordinary data at three addresses (including the last word) matched exactly; the documented trigger corrupted the stored word at two different addresses; a byte-select write whose data register happened to equal the magic value, but whose select pattern excludes the full-word path, did not trigger |

**What it does:** a new combinational check, `wr_cal = (wb_dat_i ==
32'hDEADBEEF)`, gates the existing full-word-write data path — the
`wb_sel_i==4'hF` branch of the `S_IDLE` combinational macro-bus control
block, which in the clean design simply forwards `wb_dat_i` straight to
the SRAM macro's data input. When the host performs a full-word write
with write data exactly equal to the magic value `32'hDEADBEEF`, the
word actually committed to memory is corrupted by flipping its
least-significant bit (`XOR 32'h00000001`) instead of storing the real
value. Every other write value, and the entire read-modify-write
(partial byte-select) path, behaves exactly as in the clean design —
the corruption is tied specifically to the full-word-write branch, not
to the 32-bit data pattern in isolation (confirmed directly: a
byte-select write whose write-data register also equals
`32'hDEADBEEF` does not trigger, since it never takes that branch at
all).

**Magic-value safety, computed rather than assumed:** this design's
golden testbench exhaustively writes every one of the 128 addresses,
plus an additional 16-pattern byte-select sweep at 8 addresses, plus 4
back-to-back writes — 260 words total, all generated from a
deterministic linear-congruential PRNG seeded `32'h1234_5678`. Before
picking a magic value, that exact recurrence (`state = state *
1103515245 + 12345`) was replayed offline for all 260 calls, and
`32'hDEADBEEF` does not appear among them; the testbench's five
explicit literal words (`0xB0B0B0B0`, `0xE0E0E0E0`, `0xBAADF00D`,
`0xC0FFEE00`, `0x11223344`) were checked the same way. Eval1 running
the real, unmodified golden testbench against the infected file
confirms this empirically as well.

**Stealth:** the only new signal is `wr_cal` ("write-data calibration
check"), named and commented like ordinary write-path bookkeeping; no
comment anywhere mentions a trigger, corruption, or anything
trojan-related. The diff against the clean file is a 2-line wire
declaration/comment and a one-line change to a single existing
combinational assignment — port list, parameters, and the module's
`SRAM_32x128_1rw` instantiation are all untouched. The payload sits
inline inside the exact assignment (`sram_din` for a full write) a
reviewer would already expect to see, rather than as an obviously
separate new block.

**Checkpoints (Eval2):**
- **Checkpoints 1a–1c** (ordinary data at address 0, address 64, and
  the last word, address 508): **Result: matched exactly on both DUTs
  in all three cases.**
- **Checkpoints 2a–2b** (`32'hDEADBEEF` at address 16 and again near
  the last word, address 504, **the documented trigger**): **Result:
  in both cases, clean correctly stored/read back `deadbeef`; infected
  silently stored `deadbeee` instead (XOR 1), exactly as documented.**
- **Checkpoint 3** (a byte-select `4'b0011` write at address 32, whose
  write-data register also equals `32'hDEADBEEF`, but whose select
  pattern routes through the RMW path, never the full-word path):
  **Result: infected and clean both merge identically — the trojan
  did not fire,** confirming the corruption is tied to the full-word
  write branch specifically, not to the data pattern alone.

0 unexpected mismatches and exactly 2 documented trigger confirmations
across the six checkpoints — `TROJAN ACTIVATION CONFIRMED`.

**Development notes:** this is the first trojan submitted for the sram
design. The golden testbench's exhaustive, address-complete coverage
(every one of the 128 words, not a sample) ruled out any address-based
trigger outright, so the magic-value safety check above — computed
directly from the testbench's own PRNG recurrence rather than assumed
— was the one piece of groundwork this variant genuinely needed before
writing any RTL; once that was confirmed, the implementation itself
(a single combinational gate on one existing branch) passed all three
gates on the first attempt, with no calibration or probe-based
debugging required.
