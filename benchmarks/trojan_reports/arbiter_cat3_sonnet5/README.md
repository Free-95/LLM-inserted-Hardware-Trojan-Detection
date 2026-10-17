# arbiter (wb_arbiter_2m1s) — cat3_data_leakage — variant 0

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping (1022.2 µm²) |
| Eval1 | Icarus Verilog, full 7-section testbench | PASS — all original checks pass |
| Eval2 | Icarus Verilog, infected vs. clean | PASS — `TROJAN ACTIVATION CONFIRMED`, exactly 1/42 transactions mismatched (magic address + leak_bit=1); the magic address with leak_bit=0 correctly produces NO visible deviation, confirming the leak is genuinely data-dependent rather than a fixed corruption |

**What it does:** when the currently-granted master reads the magic address
`0x00000900` (unreachable by golden traffic), bit 0 of the response data
sent back is XORed with bit 0 of the **other, non-granted master's own
address bus**. This is a real cross-master side-channel: by issuing one
special read, a master can learn one bit of what the other master is
currently presenting on its address lines — information the Wishbone
protocol never legitimately exposes to it. Because the deviation's value
*equals* the leaked bit, a magic-address read while the other master's
address LSB happens to be 0 produces no visible change at all, even though
the trojan fired — matching the real semantics of an information-leakage
primitive rather than a blind corruption.

**Design iteration worth noting:** my first attempt leaked the internal
`last_grant` register. A direct hierarchical probe before running the full
pipeline (same discipline as the cat2 variant) revealed `last_grant` always
exactly equals `grant` in this design — every branch of the arbitration case
statement sets them together — so a master leaking its own `last_grant`
would only ever learn something it already knows (its own grant status).
That's not a meaningful leak. Redesigned to leak the *other* master's
address bit instead, which is genuinely new information to the master
receiving it, then re-verified the trigger fires correctly with a direct
probe before running Eval0/Eval1/Eval2 for real.
