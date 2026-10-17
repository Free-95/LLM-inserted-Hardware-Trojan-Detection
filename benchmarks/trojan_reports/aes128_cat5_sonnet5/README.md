# aes128 — cat5_parametric_rare_value_corruption — submodule-level variant (real sky130 PDK)

Per your instruction, this trojan is **not** in the top module `aes_128.v`
at all — the only file touched is `table.v`, specifically the shared `S4`
substitution block. That block is instantiated 13 times across the whole
core (4x inside `final_round` in `round.v`, once per round inside
`expand_key_128` in `aes_128.v`), so this single low-level edit silently
rides along into every one of those 13 sites without touching either of
the files that call it — a much more realistic "supply-chain" trojan
placement than always editing the top-level datapath.

Stealth requirements applied:
- No trojan-referencing comments in `table.v` (only the original
  `/* substitue four bytes in a word */` comment remains).
- Added signals named `raw`, `mon_d`, `mon_now` — reads like an ordinary
  internal monitor/diagnostic tap, not anything trigger/payload-labeled.
- `activation_testbench.v` uses `clean` naming throughout and embeds the
  full clean reference design in the same file, matching your convention.

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + your real sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines |
| Eval1 | Icarus Verilog                      | PASS — all 182 golden vectors match |
| Eval2 | Icarus Verilog, infected vs. `clean`| PASS — `TROJAN ACTIVATION CONFIRMED`, exactly 1/60 cycles mismatched, 0 unexpected mismatches |

**What it does:** inside the shared `S4` block, if the 32-bit value handed
to *this instance* equals `0xDEADC0DE` (P = 2⁻³² per instance per cycle),
bit 24 of that instance's own output is flipped for that one cycle. The
included Eval2 activation vector makes this fire inside the **round-1 key
schedule** (by choosing a key whose low 32 bits rotate to exactly
`0xDEADC0DE`), and the corruption then propagates through the remaining
AES rounds to the final ciphertext, exactly like a genuine single-bit
key-schedule fault would.

**Bug caught and fixed during development:** my first Eval2 attempt
hand-wrote the embedded "clean" reference design (`one_round_clean`,
`final_round_clean`, etc.) from memory instead of copying the real
`round.v`/`table.v` source, and got the port list and the diagonal
ShiftRows/MixColumns XOR pattern of `one_round` wrong. That produced an
all-`X` clean output and 59/60 cycles flagged as "unexpected mismatches" —
immediately caught by Eval2's own pass criteria, which refused to call it
a pass. I rebuilt the embedded clean reference by programmatically
extracting and renaming the *exact* original modules instead of
transcribing them, and the corrected version passes clean.
