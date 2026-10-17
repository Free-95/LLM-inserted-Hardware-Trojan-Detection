# aes128 — cat3_data_leakage — variant 0 

| Gate  | Tool                              | Result |
|-------|-------------------------------------|--------|
| Eval0 | Yosys + sky130_fd_sc_hd lib | PASS — exit 0, 0 `ERROR` lines, full technology mapping |
| Eval1 | Icarus Verilog                      | PASS — all 182 golden vectors match |
| Eval2 | Icarus Verilog, infected vs. `clean` | PASS — `TROJAN ACTIVATION CONFIRMED`, exactly 1/60 cycles mismatched (the trigger cycle), 0 unexpected mismatches |

**What it does:** when `state[31:24]==0x7E` and `key[31:24]==0x3D` occur on
the same applied cycle (P = 2⁻¹⁶), bit 0 of the registered AES key is
multiplexed onto bit 48 of the ciphertext for that one cycle only — a
genuine information-leakage primitive (the deviation's VALUE carries the
secret bit, rather than being a fixed corruption pattern): if that key bit
happens to be 0, there is no visible deviation at all even though the trigger
fired, which is why the Eval2 activation vector was deliberately chosen with
key bit 0 = 1.
