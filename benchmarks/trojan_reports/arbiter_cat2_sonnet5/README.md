# arbiter (wb_arbiter_2m1s) — cat2_sequential_counter_timebomb — variant 0

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (1217.4 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — all original checks pass |
| Eval2 | Icarus Verilog, infected vs. clean | PASS — `TROJAN ACTIVATION CONFIRMED`, fired exactly once (the documented 3rd occurrence), zero unexpected mismatches across 44 other transactions (40 swept + 1st/2nd/interleave/4th-saturated) |

**What it does:** a small saturating counter (`hit_cnt`, edge-detected via
`addr_hit_edge`/`prev_hit`) counts DISCRETE requests to the address
`0x00000700` — an address that's structurally unreachable by the golden
testbench's own traffic generators (random addresses cap at `0x3FC`,
explicit fixed test addresses cap at `0x500`). On the 3rd such occurrence
only, `s_we_o` (the write-enable forwarded to the shared slave) is flipped,
silently turning that one read into a write or vice versa. This is a
different corruption surface from the cat1 variant (which flipped a write-
data bit): here the counter-driven payload corrupts a *control* signal
instead, demonstrating category diversity within the same design.

**Process note:** after the previous cat1 variant's silent width-truncation
bug (a trojan that simply never fired, which Eval1/Eval2 alone can't
distinguish from correct dormancy), I added a direct hierarchical-signal
debug probe for this variant *before* trusting a clean Eval1/Eval2 pass:
confirmed `hit_cnt` genuinely counts 0→1→2→3 across repeated magic-address
transactions and `mode_fire` asserts on exactly the 3rd, not before or
after, prior to running the full three-gate pipeline for real.
