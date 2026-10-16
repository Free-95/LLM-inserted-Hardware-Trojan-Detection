#!/usr/bin/env python3
"""
================================================================================
RTL Hardware Trojan Insertion & Detection Dataset Generator -- v1
================================================================================
Port of hls_trojan_harness_v2.py to RTL (Verilog/SystemVerilog) designs,
targeting the clean baseline cores collected in this project (picorv32, AES-128,
SHA-256, UART, SPI, I2C, SRAM controller, Wishbone arbiter, FFT, systolic GEMM).

Carries forward every lesson learned building and validating those designs'
testbenches in this conversation:
  - Loud, non-silent toolchain detection (no fallback mode exists for RTL the
    way g++ could stand in for a missing Vitis HLS -- a Verilog simulator is
    not optional, so this harness aborts clearly rather than ever faking it).
  - A structural-integrity guard that rejects LLM output which strips ports,
    parameters, or submodule instantiations to dodge a compile error, the
    same failure mode that corrupted early HLS variants.
  - Dormancy (Eval1) is verified by actually compiling the infected module
    against your EXISTING, already-validated self-checking testbench and
    grepping for "SIMULATION PASSED" -- the same convention used throughout
    this project, not a new one invented for this harness.
  - A genuine two-gate closed loop (Eval1 dormancy, Eval2 adversarial
    activation) with bounded repair attempts, mirroring the HLS flow exactly.

RTL-SPECIFIC DIFFERENCES FROM THE HLS VERSION:
  - Per the user's explicit instruction: for a multi-file design, the LLM is
    NOT required to touch every file. The harness selects ONE target file per
    variant from that design's `insertable` list, shows the LLM ONLY that
    file, and keeps every other file of the design byte-for-byte as the clean
    baseline for both compilation and both Eval gates. An unnoticeable Trojan
    in a single module of a large design is treated as a full success, not a
    partial one.
  - RTL Trojans are frequently SEQUENTIAL/TEMPORAL (a rare bit pattern seen
    over several cycles, a free-running counter reaching a rare value, a
    hang/stall condition) rather than purely combinational, so trigger specs
    and the adversarial activation testbench are built around that.
  - Eval2 (activation) is driven by a small, LLM-authored "activation
    sequence" task that is spliced into a harness wrapping the SAME
    already-validated golden testbench's DUT instantiation (via a generated
    top-level wrapper), rather than a bespoke custom testbench from scratch --
    this keeps Eval2 honest about actually exercising the public interface.
"""

import os
import re
import json
import shutil
import random
import subprocess
import csv
from pathlib import Path
from datetime import datetime

# ==========================================================================
# 1. GLOBAL CONFIGURATION
# ==========================================================================
INPUT_DIR = Path(os.environ.get("RTL_INPUT_DIR", "clean_baseline"))
OUTPUT_DIR = Path(os.environ.get("RTL_OUTPUT_DIR", "infected_rtl"))
REPORTS_DIR = Path(os.environ.get("RTL_REPORTS_DIR", "trojan_reports"))
VARIANTS_PER_CATEGORY = int(os.environ.get("VARIANTS_PER_CATEGORY", "4"))
MAX_REPAIR_ATTEMPTS = int(os.environ.get("MAX_REPAIR_ATTEMPTS", "3"))
SIM_TIMEOUT = 60          # seconds, wall-clock guard around vvp itself

# -------------------------------------------------------------------------
# LLM CONFIGURATION -- fill these in before running.
# Uses the `openai` package's client; this works for the real OpenAI API as
# well as any OpenAI-compatible endpoint (vLLM, LiteLLM, OpenRouter, Azure
# OpenAI via its own base_url, etc.) by setting OPENAI_BASE_URL accordingly.
#   pip install openai
# -------------------------------------------------------------------------
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "PUT_YOUR_API_KEY_HERE")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-4.1")
OPENAI_BASE_URL = os.environ.get("OPENAI_BASE_URL")  # leave unset for the default OpenAI endpoint
LLM_TEMPERATURE = 0.7
LLM_MAX_TOKENS = 8000

# -------------------------------------------------------------------------
# SIMULATOR -- hardcoded path first (same pattern that proved reliable for
# the Vivado/Vitis tools earlier in this project: PATH edits made via a GUI
# only apply to NEW processes, and relying solely on PATH/shutil.which was
# the single biggest source of "it's installed but the script can't find it"
# problems), falling back to a PATH search, then aborting loudly -- there is
# no legitimate substitute for a real Verilog simulator the way a native
# compiler could stand in for a missing HLS toolchain.
# -------------------------------------------------------------------------
IVERILOG_BIN = os.environ.get("IVERILOG_PATH", r"/usr/bin/iverilog")
VVP_BIN      = os.environ.get("VVP_PATH", r"/usr/bin/vvp")

# -------------------------------------------------------------------------
# SYNTHESIS CHECK -- Yosys + SkyWater sky130 liberty. This is the Eval0 gate
# the HLS harness gets "for free" from Vitis HLS's own csynth step but the
# RTL side never had: iverilog proves functional dormancy/activation but
# will happily simulate stuff that cannot be mapped to real standard cells
# (combinational loops, latches Yosys refuses to infer cleanly, X-propagation
# tricks, behavioral constructs with no synthesizable equivalent). Every
# saved variant must pass a real `yosys synth` -> sky130 `abc -liberty`
# technology-mapping run with zero errors before it is accepted.
# -------------------------------------------------------------------------
YOSYS_BIN = os.environ.get("YOSYS_PATH", r"/usr/bin/yosys")
SKY130_LIBERTY = os.environ.get(
    "SKY130_LIBERTY_PATH",
    r"/usr/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
)
# NOTE: the default path above is just a common install location to try before
# giving up -- it is NOT bundled with this script and nothing synthetic is
# substituted if it's missing (see check_toolchain(): REQUIRE_SYNTH_GATE=1 by
# default aborts the whole run rather than faking Eval0). Point
# SKY130_LIBERTY_PATH at your own real sky130A liberty file.
SYNTH_TIMEOUT = 120
REQUIRE_SYNTH_GATE = os.environ.get("REQUIRE_SYNTH_GATE", "1").lower() in ("1", "true", "yes")

TOOLCHAIN_MODE = "UNVERIFIED"
YOSYS_AVAILABLE = False


def _find_binary(hardcoded_path: str, bare_name: str) -> str | None:
    if os.path.isfile(hardcoded_path):
        return hardcoded_path
    found = shutil.which(bare_name)
    if found:
        return found
    if os.name == "nt":
        for ext in (".exe", ".bat", ".cmd"):
            found = shutil.which(bare_name + ext)
            if found:
                return found
    return None


def check_toolchain() -> str:
    """
    Verifies a real Verilog simulator (Icarus Verilog: iverilog + vvp) is
    available and prints an unmissable banner. Unlike the HLS harness, there
    is no ALLOW_NATIVE_FALLBACK mode here: a native C/C++ compiler cannot
    meaningfully stand in for a missing Verilog simulator (there is no
    "syntax-only" substitute that proves anything about RTL behavior), so a
    missing simulator is always a hard abort.
    """
    global TOOLCHAIN_MODE
    iv = _find_binary(IVERILOG_BIN, "iverilog")
    vvp = _find_binary(VVP_BIN, "vvp")

    print(f"\n{'#'*70}")
    if iv and vvp:
        TOOLCHAIN_MODE = "ICARUS"
        print("[TOOLCHAIN CHECK] Icarus Verilog toolchain DETECTED.")
        print(f"    iverilog : {iv}")
        print(f"    vvp      : {vvp}")
        print("    All Eval1/Eval2 results in this run are REAL RTL simulation results.")
    else:
        TOOLCHAIN_MODE = "MISSING"
        print("[TOOLCHAIN CHECK] !!! NO VERILOG SIMULATOR FOUND !!!")
        print(f"    Checked hardcoded path : {IVERILOG_BIN}")
        print(f"    Checked hardcoded path : {VVP_BIN}")
        print("    ...and 'iverilog'/'vvp' were not found on PATH either.")
        print()
        print("    Fix: install Icarus Verilog (e.g. `apt-get install iverilog`),")
        print("    then either edit IVERILOG_BIN/VVP_BIN at the top of this script,")
        print("    or set env vars before running:")
        print(r'        set IVERILOG_PATH=C:\path\to\iverilog.exe')
        print(r'        set VVP_PATH=C:\path\to\vvp.exe')
        print(f"{'#'*70}\n")
        raise SystemExit(
            "No Verilog simulator found. Install Icarus Verilog or fix "
            "IVERILOG_BIN/VVP_BIN (or IVERILOG_PATH/VVP_PATH) before running "
            "this harness. There is no fallback mode for RTL -- a missing "
            "simulator means Eval1/Eval2 cannot run at all."
        )
    print(f"{'#'*70}\n")

    # ---- Yosys + sky130 synthesis-gate check (separate, non-fatal unless
    # REQUIRE_SYNTH_GATE=1, which is the default) ----
    global YOSYS_AVAILABLE
    yosys_path = _find_binary(YOSYS_BIN, "yosys")
    lib_ok = os.path.isfile(SKY130_LIBERTY)
    print(f"{'#'*70}")
    if yosys_path and lib_ok:
        YOSYS_AVAILABLE = True
        print("[TOOLCHAIN CHECK] Yosys + sky130 liberty DETECTED.")
        print(f"    yosys      : {yosys_path}")
        print(f"    sky130 lib : {SKY130_LIBERTY}")
        print("    Every saved variant will additionally pass a real sky130")
        print("    technology-mapped synthesizability check (Eval0).")
    else:
        YOSYS_AVAILABLE = False
        print("[TOOLCHAIN CHECK] !!! Yosys / sky130 liberty NOT fully available !!!")
        if not yosys_path:
            print(f"    yosys not found (checked {YOSYS_BIN} and PATH).")
        if not lib_ok:
            print(f"    sky130 liberty not found at: {SKY130_LIBERTY}")
            print("    Install the sky130 PDK (e.g. via `pip install volare` then")
            print("    `volare enable <version>`, or apt's `yosys` + `sky130-pdk` on")
            print("    distros that package it) and set SKY130_LIBERTY_PATH if your")
            print("    install path differs from the default above.")
        if REQUIRE_SYNTH_GATE:
            print("    REQUIRE_SYNTH_GATE=1 (default) -> ABORTING run: without a real")
            print("    synthesis gate, a variant that only simulates (e.g. relies on")
            print("    X-propagation, a combinational loop, or a non-synthesizable")
            print("    construct the Trojan hides behind) could be saved into the")
            print("    dataset labeled 'infected' while being structurally unlike a")
            print("    real ASIC/FPGA netlist -- which would poison GNN training on")
            print("    gate-level/structural graph features.")
            print(f"{'#'*70}\n")
            raise SystemExit(
                "Yosys + sky130 liberty not found and REQUIRE_SYNTH_GATE is enabled "
                "(default). Install Yosys and the sky130 PDK, or explicitly set "
                "REQUIRE_SYNTH_GATE=0 if you understand variants will then be saved "
                "without a real synthesizability check."
            )
        print("    REQUIRE_SYNTH_GATE=0 -> continuing WITHOUT the synthesis gate.")
        print("    Saved variants will be tagged UNVERIFIED_SYNTH in their metadata.")
    print(f"{'#'*70}\n")
    return TOOLCHAIN_MODE


# ==========================================================================
# 2. DESIGN REGISTRY
# ==========================================================================
# Matches the actual `clean_baseline/<design>/` directory layout exactly
# (directory names, filenames, and the non-Verilog support files each
# testbench reads at runtime via $readmemh/$fopen).
#
# `files`: every RTL source file the design needs to compile (relative to
#          INPUT_DIR/<key>/), EXCLUDING the testbench itself.
# `testbench`: the design's own already-validated self-checking testbench
#          (NEVER modified by the LLM; this is the Eval1 dormancy gate).
# `insertable`: the subset of `files` the LLM is allowed to target -- real
#          synthesizable DUT modules only. Pure testbench-side behavioral
#          stubs (e.g. i2c_slave_model.v, wb_master_model.v, spi_slave_model.v)
#          and non-module header files (spi_defines.v, just `define macros)
#          are intentionally excluded: they are test infrastructure, not the
#          design under test. Per the user's instruction, for a multi-file
#          design the harness picks exactly ONE file from this list per
#          variant, chosen RANDOMLY (see pick_target_file), not in any fixed
#          rotation -- an unnoticeable Trojan in just one module of a large
#          design counts as a full, successful variant.
# `support_files`: non-Verilog files (hex memory images, vector files) that
#          must be copied into the simulation working directory (because the
#          testbench reads them at runtime) but are never compiled or
#          insertable.
# `extra_sim_args`: any extra iverilog flags this design's testbench needs
#          (e.g. `-g2012` for the SystemVerilog FFT testbench/top).
# -------------------------------------------------------------------------
DESIGN_REGISTRY = {
    "aes128": {
        "top_module": "aes_128",
        "files": ["aes_128.v", "round.v", "table.v"],
        "testbench": "tb_aes_128.v",
        "insertable": ["aes_128.v", "round.v", "table.v"],
        "support_files": ["vectors.hex"],
        "extra_sim_args": [],
    },
    "arbiter": {
        "top_module": "wb_arbiter_2m1s",
        "files": ["wb_arbiter_2m1s.v"],
        "testbench": "tb_wb_arbiter.v",
        "insertable": ["wb_arbiter_2m1s.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
    "fft": {
        "top_module": "fft_8point",
        "files": ["fft_8point.sv", "butterfly_2point.v", "cpx_mad.v",
                  "cordic_sincos.v", "cordic_twiddle_generator.v",
                  "rca_16bit.v", "vedic_multiplier_q8_8.v"],
        "testbench": "tb_fft_8point.sv",
        "insertable": ["fft_8point.sv", "butterfly_2point.v", "cpx_mad.v",
                       "cordic_sincos.v", "cordic_twiddle_generator.v",
                       "rca_16bit.v", "vedic_multiplier_q8_8.v"],
        "support_files": [],
        "extra_sim_args": ["-g2012"],
    },
    "gemm": {
        "top_module": "systolic_array_gemm",
        "files": ["systolic_array_gemm.v", "systolic_pe.v"],
        "testbench": "tb_systolic_array_gemm.v",
        "insertable": ["systolic_array_gemm.v", "systolic_pe.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
    "i2c": {
        "top_module": "i2c_master_top",
        "files": ["i2c_master_top.v", "i2c_master_bit_ctrl.v",
                  "i2c_master_byte_ctrl.v", "i2c_slave_model.v",
                  "wb_master_model.v"],
        "testbench": "tb_i2c_top.v",
        "insertable": ["i2c_master_top.v", "i2c_master_bit_ctrl.v",
                       "i2c_master_byte_ctrl.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
    "picorv32": {
        "top_module": "picorv32",
        "files": ["picorv32.v"],
        "testbench": "testbench.v",
        "insertable": ["picorv32.v"],
        "support_files": ["firmware.hex"],
        "extra_sim_args": [],
    },
    "sha256": {
        "top_module": "sha256_core",
        "files": ["sha256_core.v", "sha256_k_constants.v", "sha256_w_mem.v"],
        "testbench": "tb_sha256_core.v",
        "insertable": ["sha256_core.v", "sha256_k_constants.v", "sha256_w_mem.v"],
        "support_files": ["sha_blocks.hex", "sha_digests.hex", "sha_meta.txt"],
        "extra_sim_args": [],
    },
    "spi": {
        "top_module": "spi_top",
        "files": ["spi_top.v", "spi_shift.v", "spi_clgen.v", "spi_defines.v",
                  "spi_slave_model.v", "wb_master_model.v"],
        "testbench": "tb_spi_top.v",
        "insertable": ["spi_top.v", "spi_shift.v", "spi_clgen.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
    "sram": {
        "top_module": "wb_sram_controller",
        "files": ["wb_sram_controller.v", "SRAM_32x128_1rw.v"],
        "testbench": "tb_wb_sram_controller.v",
        "insertable": ["wb_sram_controller.v", "SRAM_32x128_1rw.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
    "uart": {
        "top_module": "impl_top",
        "files": ["impl_top.v", "uart_rx.v", "uart_tx.v"],
        "testbench": "tb_uart.v",
        "insertable": ["impl_top.v", "uart_rx.v", "uart_tx.v"],
        "support_files": [],
        "extra_sim_args": [],
    },
}

PASS_TOKEN = "SIMULATION PASSED"
FAIL_TOKEN = "SIMULATION FAILED"


# ==========================================================================
# 3. TROJAN CATEGORIES (RTL-adapted)
# ==========================================================================
# Mirrors the HLS harness's 7-category taxonomy, re-grounded in RTL-native
# trigger/payload mechanisms. Categories 1-5 are "attack" Trojans (payload
# corrupts data, leaks a secret, or denies service); category 6 is a benign
# watermark (useful for watermark-detection research, not malicious);
# category 7 targets bus/protocol-level violations specific to RTL
# interconnects (handshake signals), which has no direct HLS analogue.
# -------------------------------------------------------------------------
TROJAN_CATEGORIES = {
    "cat1_combinational_rare_trigger": (
        "Combinational Rare-Trigger Logic Bomb: trigger condition is a rare "
        "AND/XOR of several existing internal signals or input bits combining "
        "to a specific pattern with very low natural probability (e.g. P < 2^-8). "
        "Payload corrupts a data or control signal only in that cycle."
    ),
    "cat2_sequential_counter_timebomb": (
        "Sequential Counter Time-Bomb: a small hidden free-running counter "
        "(reusing an existing clock-enable condition, not a new always-active "
        "counter that would show up as obviously extra toggling activity) "
        "that corrupts behavior once it reaches a specific rare count, then "
        "optionally resets or stays latched."
    ),
    "cat3_data_leakage": (
        "Information Leakage: on a rare trigger, multiplexes internal secret-ish "
        "state (e.g. a key/constant register, an internal accumulator) onto a "
        "legitimately-observable output bus or a normally-unused output bit, "
        "without changing that output's value under any normal/golden-testbench "
        "condition."
    ),
    "cat4_dos_hang": (
        "Denial-of-Service / Hang Trojan: on a rare trigger, forces a "
        "ready/valid/ack/done/busy-style control signal to stay permanently "
        "deasserted (or a state machine to loop forever), hanging the core. "
        "Must remain fully dormant (i.e. never trigger) under the golden "
        "testbench's normal input space."
    ),
    "cat5_parametric_rare_value_corruption": (
        "Parametric Rare-Value Corruption: corrupts an arithmetic/logic result "
        "only when a specific operand, address, index, or internal counter "
        "equals one particular rare value (a single address, a single ALU "
        "input, a single loop/twiddle/round index), leaving every other value "
        "bit-exact. This is the category most likely to survive a narrow "
        "test suite and is specifically what this project's own testbenches "
        "were built to catch via broad/randomized/exhaustive coverage."
    ),
    "cat6_watermark": (
        "Benign Watermark: inserts a non-malicious, functionally-silent marker "
        "(e.g. a specific rare input pattern causes one otherwise-unused output "
        "bit to pulse, with zero effect on any documented functional output) "
        "for watermark-detection research. Not intended to corrupt data or "
        "deny service -- Eval2 for this category checks the marker fires "
        "under its trigger and NOTHING else changes."
    ),
    "cat7_protocol_violation": (
        "Bus/Handshake Protocol Violation: on a rare trigger, violates the "
        "design's bus protocol contract in a way other than data corruption or "
        "hanging -- e.g. asserts ack/valid without a corresponding "
        "request/stb, double-asserts a grant to two requesters simultaneously, "
        "or drops a busy/lock signal one cycle early -- exploiting protocol-level "
        "assumptions the golden testbench may not stress-test as directly as "
        "raw data values."
    ),
}


# ==========================================================================
# 4. PRESERVATION DIRECTIVE
# ==========================================================================
# Directly descended from the HLS harness's PRESERVATION_DIRECTIVE, which
# existed because an early repair loop, faced with a compile error, deleted
# the real HLS type system rather than fixing the actual bug. The RTL
# failure mode is structurally the same risk (strip ports/parameters/
# submodule instantiations to dodge an error) with RTL-specific specifics.
# -------------------------------------------------------------------------
PRESERVATION_DIRECTIVE = """
CRITICAL PRESERVATION RULES (violating any of these invalidates your output):
1. Do NOT change the module's port list: every port name, direction (input/
   output/inout), width, and signedness must remain character-for-character
   identical to the original. The testbench instantiates this module by name
   and will not compile or will silently misconnect if the port list changes.
2. Do NOT change any `parameter` or `localparam` name or default value unless
   the Trojan logic itself requires a new, ADDITIONAL parameter (never remove
   or repurpose an existing one).
3. Do NOT remove, rename, or change the port list of any submodule
   instantiation that exists in the original file (e.g. do not strip out an
   instantiated adder/multiplier/memory macro to "simplify" your edit).
4. Do NOT remove any existing `always`/`initial` block's functional behavior
   outside of the specific lines your Trojan logic needs to touch. Your only
   job is to add a rare-trigger condition and a payload; the rest of the
   module's logic must behave identically to the original under every input
   that does not satisfy your trigger.
5. If you hit a compile/synthesis error, that means your OWN added logic has
   a bug (a width mismatch, an undeclared signal, a syntax error) -- it does
   NOT mean you should delete or simplify the original module's structure to
   work around it. Fix your own addition instead.
6. You are given exactly ONE file to modify for this variant. Do not assume
   you need to (or are allowed to) change any other file in the design --
   every other file is held fixed as the clean baseline. A real, effective
   Trojan hidden in a single module of a larger multi-file design is a
   complete, successful variant on its own.
7. The design must remain fully synthesizable, standard Verilog/SystemVerilog
   -- no simulation-only constructs (`$display` for anything other than
   genuinely harmless debug, `#` delays as functional logic, etc.) as part of
   the Trojan payload itself.
"""

ACTIVATION_DIRECTIVE = """
IMPORTANT OUTPUT FORMAT REQUIREMENTS:
Provide your response as exactly two blocks, each starting with its own
marker line and containing nothing else on that line:

/// [INFECTED_MODULE]
<the complete, modified file content for the ONE file you were given>

/// [TRIGGER_SPEC]
<a single-line JSON object describing exactly how to activate the Trojan,
 see schema below>

/// [ACTIVATION_SEQUENCE]
<a self-contained Verilog `task automatic activate_trojan;` body, written
 against the SAME top-level signal names used in the provided golden
 testbench (you will be shown that testbench's DUT instantiation and its
 existing helper tasks/signals), that drives the public interface to reach
 your documented trigger condition and leaves enough time for the payload's
 effect to become observable. Drive the trigger stimulus itself (addresses,
 data, control signals) exclusively through the same public interface the
 golden testbench already uses. For CHECKING the effect afterward, you may
 reference the DUT instance hierarchically using the same instance name the
 golden testbench uses (commonly `dut`) -- e.g. `dut.some_internal_signal`
 -- which is the normal way to confirm an internal-state payload (not just
 ones that reach an output port) actually fired.

 SEQUENCING: this task is spliced into the SAME module as the golden
 testbench and is only called AFTER the golden testbench's own normal
 sequence has fully completed (so the DUT will be left in whatever state
 the golden run's last transaction left it in -- not necessarily reset).
 If your trigger needs a known-clean starting state, have your task's first
 statements drive the design's normal reset/idle sequence itself before
 proceeding to the trigger, using the same reset task/signals the golden
 testbench's own code uses.

 Your task MUST end by checking the documented observable_effect yourself
 (e.g. comparing a readable output against the expected clean value) and
 printing the EXACT line `TROJAN ACTIVATION CONFIRMED` (nothing more on
 that line) only if the effect genuinely occurred. If the effect did not
 occur, do not print that line -- print a brief diagnostic instead.>

TRIGGER_SPEC JSON schema (all fields required):
{
  "category": "<one of the 7 category keys you were given>",
  "trigger_description": "<one sentence, human-readable>",
  "observable_effect": "<one sentence: exactly what output/signal differs,
                         and how, once activated -- e.g. 'output_data[3]
                         becomes 0xFFFF instead of the correct value' or
                         'done never asserts, simulation hangs'>",
  "expected_value_if_clean": "<the value or behavior a NON-infected design
                               would show under this same stimulus>",
  "expected_value_if_infected": "<the value or behavior AFTER activation>"
}

Do not include any text outside these three marked blocks.
"""


# ==========================================================================
# 5. STRUCTURAL INTEGRITY GUARD
# ==========================================================================
def _extract_module_header(code: str) -> str | None:
    """Pulls the `module name #(...) (...)` header text (params + ports),
    stopping at the first unmatched closing paren followed by `;`. Good
    enough for a structural diff, not a full parser."""
    m = re.search(r'\bmodule\s+\w+', code)
    if not m:
        return None
    start = m.start()
    # crude bracket-depth scan to the header's closing `;`
    depth = 0
    i = start
    seen_paren = False
    while i < len(code):
        c = code[i]
        if c == '(':
            depth += 1
            seen_paren = True
        elif c == ')':
            depth -= 1
        elif c == ';' and seen_paren and depth == 0:
            return code[start:i+1]
        i += 1
    return code[start:min(start+2000, len(code))]


def _extract_ports(header: str) -> set[str]:
    # crude: any identifier immediately following input/output/inout
    return set(re.findall(r'\b(?:input|output|inout)\b[^,;]*?\b(\w+)\s*(?:\[[^\]]*\])?\s*[,)]', header))


def _extract_param_names(code: str) -> set[str]:
    return set(re.findall(r'\b(?:parameter|localparam)\s+(?:\[[^\]]*\]\s+)?(\w+)\s*=', code))


def _extract_instantiations(code: str) -> set[str]:
    """Rough extraction of 'ModuleType instance_name (' patterns, to catch a
    submodule instantiation being deleted entirely."""
    insts = set()
    for m in re.finditer(r'\n\s*(\w+)\s+(?:#\s*\([^)]*\)\s*)?(\w+)\s*\(', code):
        mod_type, inst_name = m.group(1), m.group(2)
        if mod_type in ("input", "output", "inout", "wire", "reg", "assign",
                         "always", "initial", "begin", "end", "if", "else",
                         "module", "function", "task", "parameter", "localparam"):
            continue
        insts.add(f"{mod_type}:{inst_name}")
    return insts


def validate_rtl_integrity(clean_code: str, infected_code: str) -> tuple[bool, str]:
    """
    Pre-compile structural guard, same spirit and same reason as the HLS
    harness's validate_kernel_integrity: catch the LLM deleting real
    structure to dodge a compile error, BEFORE ever invoking the simulator.
    """
    reasons = []

    clean_header = _extract_module_header(clean_code)
    infected_header = _extract_module_header(infected_code)
    if clean_header is None:
        return True, ""  # not a module file (e.g. a `defines-only include); nothing to check
    if infected_header is None:
        return False, "STRUCTURAL INTEGRITY CHECK FAILED:\n- No `module ... (...)` header found in the infected file at all."

    clean_ports = _extract_ports(clean_header)
    infected_ports = _extract_ports(infected_header)
    missing_ports = clean_ports - infected_ports
    if missing_ports:
        reasons.append(
            f"Port(s) removed from the module interface: {sorted(missing_ports)}. "
            f"The testbench instantiates this module by its original port list; "
            f"do not add, remove, or rename ports."
        )

    clean_params = _extract_param_names(clean_code)
    infected_params = _extract_param_names(infected_code)
    missing_params = clean_params - infected_params
    if missing_params:
        reasons.append(
            f"Parameter/localparam(s) removed: {sorted(missing_params)}. "
            f"Keep every original parameter; add new ones only if your Trojan "
            f"logic genuinely needs them."
        )

    clean_insts = _extract_instantiations(clean_code)
    infected_insts = _extract_instantiations(infected_code)
    missing_insts = clean_insts - infected_insts
    if missing_insts:
        reasons.append(
            f"Submodule instantiation(s) removed: {sorted(missing_insts)}. "
            f"Do not delete existing submodule instances to simplify your edit."
        )

    if reasons:
        return False, "STRUCTURAL INTEGRITY CHECK FAILED (checked before compilation):\n- " + "\n- ".join(reasons)
    return True, ""


# ==========================================================================
# 6. PROMPT ASSEMBLY
# ==========================================================================
# -------------------------------------------------------------------------
# DIVERSIFICATION POOL -- rotated (one hint per variant_idx, cycling) into
# the system prompt so that successive variants within the same (design,
# category) pair don't all converge on the same obvious trigger mechanism
# (e.g. always "a free-running counter"), which would make the resulting
# GNN dataset easy in a way that doesn't generalize. Combined with
# LLM_TEMPERATURE ramping per variant (see pick_temperature_for_variant)
# and the random insertable-file choice already in the base script.
# -------------------------------------------------------------------------
TRIGGER_MECHANISM_HINTS = [
    "Prefer a trigger built from an XOR/AND combination of several EXISTING "
    "data or control bits (not a brand-new free-running counter).",
    "Prefer a trigger based on a specific, rare VALUE appearing on an "
    "existing address/index/select signal (a single rare address or index).",
    "Prefer a trigger that only arms after a short SEQUENCE of distinct "
    "states/conditions occurs across several cycles (sequential, not "
    "single-cycle combinational).",
    "Prefer a trigger reusing an existing but rarely-exercised corner case "
    "of the module's own state machine (an otherwise-unreachable or "
    "rarely-reached state/transition).",
    "Prefer a trigger keyed off a rare relationship BETWEEN two existing "
    "signals (e.g. operand equality, a specific difference, a parity "
    "condition) rather than either signal alone.",
    "Prefer a trigger that reuses an existing counter/register already "
    "present in the design for its legitimate purpose, keyed off one rare "
    "value it legitimately passes through, instead of adding new state.",
]


def pick_temperature_for_variant(variant_idx: int) -> float:
    """Ramps sampling temperature up with variant index so successive
    variants of the same category are less likely to be near-duplicates of
    each other, while variant 0 stays conservative/reliable."""
    return min(0.9, LLM_TEMPERATURE + 0.1 * variant_idx)


def build_system_prompt(category_key: str, design_name: str, target_filename: str,
                         full_design_file_list: list[str], variant_idx: int = 0) -> str:
    category_desc = TROJAN_CATEGORIES[category_key]
    diversity_hint = TRIGGER_MECHANISM_HINTS[variant_idx % len(TRIGGER_MECHANISM_HINTS)]
    other_files = [f for f in full_design_file_list if f != target_filename]
    other_files_note = (
        f"This design has other files ({', '.join(other_files)}) that you are "
        f"NOT being given and NOT allowed to modify -- they remain exactly as "
        f"the clean baseline. Your Trojan must be fully containable within "
        f"{target_filename} alone."
        if other_files else
        f"This design is a single file ({target_filename})."
    )
    return f"""
You are an expert hardware security red-team engineer inserting a realistic
hardware Trojan into a single RTL module, for building a labeled dataset used
to train/benchmark Trojan DETECTION tools. This is defensive security
research: the resulting dataset trains detectors, nothing here is deployed.

Design under test: {design_name}
Target file (the ONLY file you will modify): {target_filename}
{other_files_note}

Trojan category to implement: {category_key}
{category_desc}

Rules:
1. The trigger condition must be RARE under normal/random operation (roughly
   P < 2^-6 per relevant cycle/access at minimum; rarer is better) so the
   design remains dormant and passes its existing golden self-checking
   testbench unmodified.
2. The payload must be a genuine, minimal, surgical addition -- a few lines,
   not a restructuring of the module.
3. Do NOT modify the module's port list, parameters, or remove any existing
   structure (see PRESERVATION RULES below).
4. You must also supply a TRIGGER_SPEC and an ACTIVATION_SEQUENCE task (see
   OUTPUT FORMAT below) so this Trojan's presence can be verified later by an
   adversarial test, separate from the golden dormancy test.
5. Diversity guidance for this specific variant (vary your mechanism choice
   across variants rather than reusing the same idea every time):
   {diversity_hint}
6. The final file must remain fully synthesizable standard Verilog/
   SystemVerilog -- it will be technology-mapped through Yosys onto real
   sky130 standard cells, not merely simulated.
""" + PRESERVATION_DIRECTIVE + ACTIVATION_DIRECTIVE


# ==========================================================================
# 7. SIMULATION HELPERS
# ==========================================================================
def run_iverilog_sim(work_dir: Path, sources: list[Path], extra_args: list[str],
                      top_label: str) -> tuple[bool, str]:
    """
    Compiles `sources` with iverilog and runs with vvp, inside work_dir.
    Returns (ran_without_crash, combined_stdout_stderr). Does NOT itself
    decide pass/fail -- caller greps the returned text for PASS_TOKEN/
    FAIL_TOKEN, since that is the convention this project's testbenches use.
    """
    sim_out = work_dir / f"sim_{top_label}"
    compile_cmd = [IVERILOG_RESOLVED, "-o", str(sim_out)] + extra_args + [str(s) for s in sources]
    try:
        comp = subprocess.run(compile_cmd, cwd=work_dir, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=SIM_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False, "[compile] TIMEOUT"
    if comp.returncode != 0:
        return False, "[compile error]\n" + comp.stdout

    try:
        run = subprocess.run([VVP_RESOLVED, str(sim_out)], cwd=work_dir,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=SIM_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False, "[simulation] TIMEOUT (possible hang -- could itself be the Trojan, or a DoS-category activation)"
    return True, run.stdout


def run_yosys_synth_check(work_dir: Path, design_cfg: dict, design_dir: Path,
                           target_filename: str, infected_code: str,
                           top_module_name: str) -> tuple[bool, str]:
    """
    Eval0 (synthesizability gate): builds the full design (infected target
    file + every other file of the design, untouched) in work_dir, then runs
    a Yosys script that:
      1. `read_verilog -sv` on every source file,
      2. `hierarchy -check -top <top>` (fails loudly on unresolved/implicit
         black-box modules, which is itself a strong signal of a malformed
         Trojan edit),
      3. `proc; opt; fsm; opt; memory; opt; techmap; opt` generic passes,
      4. `dfflibmap -liberty <sky130> ; abc -liberty <sky130>` to actually
         technology-map onto real sky130 standard cells,
      5. `stat` to emit a cell-count summary (useful downstream as a cheap
         structural feature / sanity check that the design didn't collapse
         to a stub).
    Returns (ok, combined_log). `ok` requires a zero Yosys return code AND no
    "ERROR" lines in the log (Yosys sometimes continues after a non-fatal
    warning but we treat any ERROR line as a hard fail for dataset hygiene).
    """
    work_dir.mkdir(parents=True, exist_ok=True)
    for fname in design_cfg["files"]:
        dst = work_dir / fname
        if fname == target_filename:
            dst.write_text(infected_code)
        else:
            shutil.copy(design_dir / fname, dst)

    read_cmds = "\n".join(
        f"read_verilog -sv {fname}" for fname in design_cfg["files"]
    )
    ys_script = f"""
{read_cmds}
hierarchy -check -top {top_module_name}
proc; opt
fsm; opt
memory; opt
techmap; opt
dfflibmap -liberty {SKY130_LIBERTY}
abc -liberty {SKY130_LIBERTY}
opt_clean
stat -liberty {SKY130_LIBERTY}
"""
    ys_path = work_dir / "synth_check.ys"
    ys_path.write_text(ys_script)

    try:
        proc = subprocess.run(
            [YOSYS_RESOLVED, "-s", str(ys_path)],
            cwd=work_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=SYNTH_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        return False, "[yosys] TIMEOUT during synthesis check."

    log = proc.stdout
    if proc.returncode != 0:
        return False, f"[yosys] exited with code {proc.returncode}\n" + log[-6000:]
    if re.search(r"^ERROR", log, re.MULTILINE):
        return False, "[yosys] ERROR line(s) found in log\n" + log[-6000:]
    return True, log[-6000:]


def _guess_top_module(filename: str, code: str) -> str:
    """Best-effort top-module name for the Yosys `-top` flag: the module
    declared in the design's primary (first-listed) source file."""
    m = re.search(r'\bmodule\s+(\w+)', code)
    return m.group(1) if m else Path(filename).stem


def check_eval1_dormancy(work_dir: Path, design_cfg: dict, design_dir: Path,
                          target_filename: str, infected_code: str) -> tuple[bool, str]:
    """
    Eval1: compile the infected target file alongside every OTHER file of the
    design (untouched, copied straight from the clean baseline) plus the
    design's own existing golden testbench, and require PASS_TOKEN with no
    FAIL_TOKEN -- i.e. the Trojan must be fully dormant under the design's
    already-validated normal-operation test suite.
    """
    work_dir.mkdir(parents=True, exist_ok=True)
    for fname in design_cfg["files"]:
        dst = work_dir / fname
        if fname == target_filename:
            dst.write_text(infected_code)
        else:
            shutil.copy(design_dir / fname, dst)
    for fname in design_cfg.get("support_files", []):
        shutil.copy(design_dir / fname, work_dir / fname)
    tb_name = design_cfg["testbench"]
    shutil.copy(design_dir / tb_name, work_dir / tb_name)

    sources = [work_dir / tb_name] + [work_dir / f for f in design_cfg["files"]]
    ok, output = run_iverilog_sim(work_dir, sources, design_cfg["extra_sim_args"], "eval1")
    if not ok:
        return False, output
    if PASS_TOKEN in output and FAIL_TOKEN not in output:
        return True, output
    return False, output


def check_eval2_activation(work_dir: Path, design_cfg: dict, design_dir: Path,
                            target_filename: str, infected_code: str,
                            activation_task_body: str, trigger_spec: dict) -> tuple[bool, str]:
    """
    Eval2: wraps the design's EXISTING golden testbench file by appending a
    generated activation-check module that instantiates nothing new (it
    reuses the golden testbench's own DUT hierarchy) -- concretely, this is
    done by textually inserting the LLM's `activate_trojan` task into a COPY
    of the golden testbench and calling it right after the golden
    testbench's own normal sequence, then checking for an explicit
    "TROJAN ACTIVATION CONFIRMED" print the task is required to emit.

    This keeps Eval2 honest: the activation sequence can only drive the
    design through the same public interface signals the golden testbench
    itself already uses (the harness does not expose any new hierarchical
    access), matching the ACTIVATION_DIRECTIVE's instruction to the LLM.
    """
    work_dir.mkdir(parents=True, exist_ok=True)
    for fname in design_cfg["files"]:
        dst = work_dir / fname
        if fname == target_filename:
            dst.write_text(infected_code)
        else:
            shutil.copy(design_dir / fname, dst)
    for fname in design_cfg.get("support_files", []):
        shutil.copy(design_dir / fname, work_dir / fname)

    tb_name = design_cfg["testbench"]
    golden_tb_code = (design_dir / tb_name).read_text()

    # The activation task must directly reference the golden testbench's own
    # module-scope signals (clk, DUT port wires/regs, any helper
    # tasks/registers already declared there) exactly as named in that file
    # -- so it is spliced INSIDE that same module, not into a separate
    # module (which would only see those signals via a hierarchical path the
    # LLM was never shown and is not allowed to guess at).
    #
    # SEQUENCING: the golden testbench's own `initial` block starts driving
    # stimulus at time 0 and would otherwise run CONCURRENTLY with a second
    # spliced `initial` block -- two threads racing to drive the same DUT
    # inputs, which earlier debugging in this project traced several
    # confusing false "DUT bugs" back to. To avoid that: every literal
    # `$finish;` in the golden testbench's own body is textually replaced
    # with a trigger of a named event, so that instead of ending the whole
    # simulation, the golden testbench's own stimulus thread simply ends
    # there (having already run its full normal sequence to completion).
    # The spliced activation block waits on that SAME event before it does
    # anything at all, guaranteeing the activation sequence only starts
    # after the golden run has genuinely finished -- then calls $finish
    # itself once done.
    last_endmodule = golden_tb_code.rfind("\nendmodule")
    if last_endmodule == -1:
        return False, "[harness] could not find 'endmodule' in the golden testbench to splice the activation task into."

    module_decl_match = re.search(r'\bmodule\s+\w+[^;]*;', golden_tb_code)
    if not module_decl_match:
        return False, "[harness] could not find the golden testbench's own 'module ... ;' declaration line."
    insert_point = module_decl_match.end()

    event_decl = "\n    event eval2_golden_tb_done;\n"
    body_with_event_decl = golden_tb_code[:insert_point] + event_decl + golden_tb_code[insert_point:]

    # Replace the golden testbench's own $finish calls with the event trigger.
    # (Done after inserting the declaration so offsets below are irrelevant --
    # this is a plain global text substitution over the whole body.)
    body_rewired = re.sub(r'\$finish\s*;', '-> eval2_golden_tb_done;', body_with_event_decl)

    last_endmodule2 = body_rewired.rfind("\nendmodule")
    spliced_block = f"""
    // ---- Auto-spliced by rtl_trojan_harness_v1.py for Eval2 activation check ----
    {activation_task_body}

    initial begin
        @(eval2_golden_tb_done); // wait for the golden testbench's own normal
                                  // sequence to fully finish before taking over
        activate_trojan();
        $display("TROJAN_ACTIVATION_TASK_COMPLETED");
        $finish;
    end
"""
    eval2_code = body_rewired[:last_endmodule2] + spliced_block + body_rewired[last_endmodule2:]
    eval2_tb_path = work_dir / f"eval2_{tb_name}"
    eval2_tb_path.write_text(eval2_code)

    sources = [eval2_tb_path] + [work_dir / f for f in design_cfg["files"]]
    ok, output = run_iverilog_sim(work_dir, sources, design_cfg["extra_sim_args"], "eval2")
    if not ok:
        return False, output

    if "TROJAN_ACTIVATION_TASK_COMPLETED" not in output:
        return False, output + "\n[harness] activate_trojan() task never completed -- possible hang or task-call error."

    # The LLM-authored task is required to itself print a clear confirmation
    # string when it has verified (via its own signal checks) that the
    # documented observable_effect actually occurred.
    if "TROJAN ACTIVATION CONFIRMED" in output:
        return True, output
    return False, output + "\n[harness] activation sequence ran but did not print 'TROJAN ACTIVATION CONFIRMED' -- the documented trigger did not produce the documented effect."


# ==========================================================================
# 8. LLM CALL -- openai-library client
# ==========================================================================
# Configure via OPENAI_API_KEY / LLM_MODEL at the top of this file (or the
# matching environment variables). Nothing else needs to change below for a
# standard OpenAI-compatible chat-completions endpoint.
_openai_client = None


def _get_openai_client():
    global _openai_client
    if _openai_client is not None:
        return _openai_client
    try:
        from openai import OpenAI
    except ImportError as e:
        raise SystemExit(
            "The 'openai' package is not installed. Run:\n"
            "    pip install openai\n"
            "then re-run this script."
        ) from e
    if not OPENAI_API_KEY or OPENAI_API_KEY == "PUT_YOUR_API_KEY_HERE":
        raise SystemExit(
            "OPENAI_API_KEY is not set. Either set the OPENAI_API_KEY "
            "environment variable, or edit OPENAI_API_KEY near the top of "
            "this script."
        )
    kwargs = {"api_key": OPENAI_API_KEY}
    if OPENAI_BASE_URL:
        kwargs["base_url"] = OPENAI_BASE_URL
    _openai_client = OpenAI(**kwargs)
    return _openai_client


def call_llm(system_prompt: str, messages: list[dict], temperature: float | None = None) -> str:
    """
    Sends `system_prompt` as the system message and `messages` (the running
    [{"role": "user"/"assistant", "content": ...}, ...] conversation built up
    by the repair loop) as-is, via openai's chat.completions API. Returns the
    raw text response, expected to contain the three marked blocks described
    in ACTIVATION_DIRECTIVE.
    """
    client = _get_openai_client()
    api_messages = [{"role": "system", "content": system_prompt}] + messages
    response = client.chat.completions.create(
        model=LLM_MODEL,
        messages=api_messages,
        temperature=temperature if temperature is not None else LLM_TEMPERATURE,
        max_tokens=LLM_MAX_TOKENS,
    )
    return response.choices[0].message.content


def parse_llm_response(raw_output: str) -> tuple[str | None, dict | None, str | None]:
    """Extracts INFECTED_MODULE, TRIGGER_SPEC (parsed JSON), and
    ACTIVATION_SEQUENCE from the LLM's raw response."""
    mod_match = re.search(r'/// \[INFECTED_MODULE\]\s*\n(.*?)(?=\n/// \[TRIGGER_SPEC\])', raw_output, re.DOTALL)
    spec_match = re.search(r'/// \[TRIGGER_SPEC\]\s*\n(.*?)(?=\n/// \[ACTIVATION_SEQUENCE\])', raw_output, re.DOTALL)
    act_match = re.search(r'/// \[ACTIVATION_SEQUENCE\]\s*\n(.*)', raw_output, re.DOTALL)

    infected_code = mod_match.group(1).strip() if mod_match else None
    activation_task = act_match.group(1).strip() if act_match else None

    trigger_spec = None
    if spec_match:
        spec_text = spec_match.group(1).strip()
        try:
            trigger_spec = json.loads(spec_text)
        except json.JSONDecodeError:
            trigger_spec = None

    return infected_code, trigger_spec, activation_task


# ==========================================================================
# 9. METRICS LOGGER
# ==========================================================================
class MetricsLogger:
    def __init__(self, path: Path):
        self.path = path
        self.records = []

    def log_variant(self, design: str, category: str, variant_idx: int,
                     target_file: str, model: str,
                     eval1_attempts: int, eval1_pass: bool,
                     eval2_attempts: int, eval2_pass: bool,
                     trigger_spec: dict | None):
        record = {
            "timestamp": datetime.now().isoformat(),
            "design": design,
            "category": category,
            "variant_id": variant_idx,
            "target_file": target_file,
            "llm_model": model,
            "toolchain_mode": TOOLCHAIN_MODE,
            "eval1_dormancy_pass": eval1_pass,
            "eval1_repair_attempts": eval1_attempts,
            "eval2_activation_pass": eval2_pass,
            "eval2_repair_attempts": eval2_attempts,
            "total_attempts": eval1_attempts + eval2_attempts,
            "eval0_synth_gate": "YOSYS_SKY130" if YOSYS_AVAILABLE else "SKIPPED",
            "trigger_category": (trigger_spec or {}).get("category", "UNKNOWN"),
            "trigger_description": (trigger_spec or {}).get("trigger_description", ""),
            "observable_effect": (trigger_spec or {}).get("observable_effect", ""),
        }
        self.records.append(record)
        self._flush()

    def _flush(self):
        if not self.records:
            return
        csv_path = self.path / "rtl_trojan_metrics.csv"
        json_path = self.path / "rtl_trojan_metrics.json"
        with open(csv_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=self.records[0].keys())
            writer.writeheader()
            writer.writerows(self.records)
        with open(json_path, "w") as f:
            json.dump(self.records, f, indent=2)


# ==========================================================================
# 10. VARIANT GENERATION (closed repair loop, mirrors the HLS harness)
# ==========================================================================
def pick_target_file(design_cfg: dict) -> str:
    """Random (not rotating/deterministic) choice of which insertable file
    this variant targets, per the user's instruction that module selection
    should vary across the dataset rather than follow a fixed pattern."""
    return random.choice(design_cfg["insertable"])


def generate_and_verify_variant(design_name: str, design_cfg: dict, design_dir: Path,
                                 category_key: str, variant_idx: int, target_filename: str,
                                 metrics_logger: MetricsLogger) -> tuple[str | None, str | None, dict | None]:
    """
    Runs the closed Eval1 -> Eval2 repair loop against `target_filename`
    (chosen by the caller -- see pick_target_file -- via random.choice over
    design_cfg["insertable"], not a fixed rotation, so repeated runs of this
    pipeline produce varied coverage across a multi-file design's modules
    rather than a deterministic pattern). Returns
    (infected_code, activation_task, trigger_spec) on success, else
    (None, None, None).
    """
    clean_code = (design_dir / target_filename).read_text()
    golden_tb_code = (design_dir / design_cfg["testbench"]).read_text()

    sys_prompt = build_system_prompt(category_key, design_name, target_filename, design_cfg["files"], variant_idx)
    temperature = pick_temperature_for_variant(variant_idx)
    messages = [{"role": "user", "content": (
        f"Here is the target file, {target_filename}, the ONLY file you will modify:\n\n"
        f"```verilog\n{clean_code}\n```\n\n"
        f"Here is this design's existing golden testbench, {design_cfg['testbench']} "
        f"(already validated, NEVER modified by you -- shown so you know the exact DUT "
        f"instance name, any helper tasks/signals already defined, and the public "
        f"interface available for your ACTIVATION_SEQUENCE task to drive):\n\n"
        f"```verilog\n{golden_tb_code}\n```"
    )}]

    eval1_attempts = 0
    eval2_attempts = 0
    infected_code = None
    activation_task = None
    trigger_spec = None

    for attempt in range(1, MAX_REPAIR_ATTEMPTS + 1):
        print(f"    [*] Calling LLM ({design_name} | {category_key} | target={target_filename} | "
              f"Variant {variant_idx} | Iteration {attempt})...")
        try:
            raw_output = call_llm(sys_prompt, messages, temperature=temperature)
        except NotImplementedError as e:
            print(f"    [!] {e}")
            return None, None, None

        infected_code, trigger_spec, activation_task = parse_llm_response(raw_output)
        messages.append({"role": "assistant", "content": raw_output})

        if infected_code is None or trigger_spec is None or activation_task is None:
            print("    [!] Response missing one of INFECTED_MODULE/TRIGGER_SPEC/ACTIVATION_SEQUENCE.")
            messages.append({"role": "user", "content": (
                "Your response was missing one of the three required blocks, or "
                "TRIGGER_SPEC was not valid JSON. Re-send all three blocks exactly "
                "as specified in the OUTPUT FORMAT REQUIREMENTS."
            )})
            continue

        # ---- Structural integrity guard (before any compilation) ----
        ok, integrity_err = validate_rtl_integrity(clean_code, infected_code)
        if not ok:
            print("    [!] Structural integrity check failed. Feeding back to LLM...")
            messages.append({"role": "user", "content": integrity_err + (
                "\nFix the Trojan logic itself rather than altering the module's "
                "structure to work around this."
            )})
            continue

        # ---- Eval0: synthesizability (Yosys + sky130) ----
        if YOSYS_AVAILABLE:
            print(f"    [*] Evaluating Gate 0 (Eval0: Yosys/sky130 synthesizability)...")
            eval0_pass, eval0_log = run_yosys_synth_check(
                Path(f"/tmp/rtl_trojan_eval/{design_name}_{category_key}_v{variant_idx}_eval0"),
                design_cfg, design_dir, target_filename, infected_code,
                design_cfg.get("top_module") or _guess_top_module(target_filename, clean_code)
            )
            if not eval0_pass:
                print("    [!] Eval0 Failed (not synthesizable onto sky130). Feeding diagnostics back to LLM...")
                messages.append({"role": "user", "content": (
                    f"Eval0 (Yosys synthesis check against the sky130 standard-cell "
                    f"library) FAILED -- your edit is not valid synthesizable RTL (it "
                    f"may rely on a simulation-only construct, create an unresolved "
                    f"hierarchy, infer an unintended latch, or otherwise fail "
                    f"technology mapping). Diagnostic output:\n{eval0_log[-4000:]}\n"
                    f"Fix the Trojan logic so the file remains fully synthesizable "
                    f"standard Verilog/SystemVerilog. Resend all three blocks."
                )})
                continue
            print("    [+] Eval0 PASSED: infected module technology-maps cleanly onto sky130 standard cells.")
        else:
            eval0_log = "[harness] Eval0 skipped -- Yosys/sky130 not available (REQUIRE_SYNTH_GATE=0)."

        # ---- Eval1: dormancy ----
        eval1_attempts += 1
        print(f"    [*] Evaluating Gate 1 (Eval1: Dormancy under golden testbench)...")
        eval1_pass, eval1_log = check_eval1_dormancy(
            Path(f"/tmp/rtl_trojan_eval/{design_name}_{category_key}_v{variant_idx}_eval1"),
            design_cfg, design_dir, target_filename, infected_code
        )
        if not eval1_pass:
            print("    [!] Eval1 Failed (not dormant / compile error). Feeding diagnostics back to LLM...")
            messages.append({"role": "user", "content": (
                f"Eval1 (dormancy under the golden testbench) FAILED. The infected "
                f"module must still produce SIMULATION PASSED with no "
                f"SIMULATION FAILED under completely normal operation -- your "
                f"trigger condition fired when it should not have, or introduced an "
                f"unrelated functional bug, or there is a compile error. Diagnostic "
                f"output:\n{eval1_log[-4000:]}\n"
                f"Fix the Trojan so it synthesizes cleanly and stays fully dormant "
                f"under the golden testbench, without removing or weakening the "
                f"trigger's rarity. Resend all three blocks."
            )})
            continue
        print("    [+] Eval1 PASSED: module compiles and remains fully dormant under the golden testbench.")

        # ---- Eval2: adversarial activation ----
        eval2_attempts += 1
        print(f"    [*] Evaluating Gate 2 (Eval2: Adversarial Trigger Activation)...")
        eval2_pass, eval2_log = check_eval2_activation(
            Path(f"/tmp/rtl_trojan_eval/{design_name}_{category_key}_v{variant_idx}_eval2"),
            design_cfg, design_dir, target_filename, infected_code,
            activation_task, trigger_spec
        )
        if not eval2_pass:
            print("    [!] Eval2 Failed. Feeding activation diagnostics back to LLM...")
            messages.append({"role": "user", "content": (
                f"Eval2 (adversarial activation) FAILED. Your ACTIVATION_SEQUENCE task "
                f"either did not compile/run, or ran but did not actually reach your "
                f"documented trigger condition (the task must itself check the "
                f"documented observable_effect and print exactly the line "
                f"'TROJAN ACTIVATION CONFIRMED' once it has verified the effect "
                f"occurred). Remember: the activation task may ONLY drive signals "
                f"that already exist in the golden testbench's own public interface "
                f"-- it cannot reach into new hierarchical/internal signals. "
                f"Diagnostic output:\n{eval2_log[-4000:]}\n"
                f"Fix the activation task (or, if the trigger itself was wrong, the "
                f"Trojan logic) and resend all three blocks."
            )})
            continue
        print("    [+] Eval2 PASSED: documented trigger reliably activates the documented effect.")

        metrics_logger.log_variant(
            design=design_name, category=category_key, variant_idx=variant_idx,
            target_file=target_filename, model=LLM_MODEL,
            eval1_attempts=eval1_attempts, eval1_pass=True,
            eval2_attempts=eval2_attempts, eval2_pass=True,
            trigger_spec=trigger_spec,
        )
        return infected_code, activation_task, trigger_spec

    print(f"    [-] Exhausted {MAX_REPAIR_ATTEMPTS} repair attempts without passing both gates.")
    metrics_logger.log_variant(
        design=design_name, category=category_key, variant_idx=variant_idx,
        target_file=target_filename, model=LLM_MODEL,
        eval1_attempts=eval1_attempts, eval1_pass=False,
        eval2_attempts=eval2_attempts, eval2_pass=False,
        trigger_spec=trigger_spec,
    )
    return None, None, None


# ==========================================================================
# 11. TOP-LEVEL PIPELINE
# ==========================================================================
IVERILOG_RESOLVED = None
VVP_RESOLVED = None
YOSYS_RESOLVED = None


def run_dataset_pipeline(designs: list[str] | None = None):
    global IVERILOG_RESOLVED, VVP_RESOLVED, YOSYS_RESOLVED

    check_toolchain()
    IVERILOG_RESOLVED = _find_binary(IVERILOG_BIN, "iverilog")
    VVP_RESOLVED = _find_binary(VVP_BIN, "vvp")
    YOSYS_RESOLVED = _find_binary(YOSYS_BIN, "yosys")

    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    metrics_logger = MetricsLogger(REPORTS_DIR)

    target_designs = designs or list(DESIGN_REGISTRY.keys())

    print(f"\n{'='*70}")
    print("[*] Starting RTL Hardware Trojan Dataset Generation Pipeline")
    print(f"[*] Designs configured: {len(target_designs)}")
    print(f"[*] Toolchain mode: {TOOLCHAIN_MODE}")
    print(f"{'='*70}\n")

    for design_name in target_designs:
        if design_name not in DESIGN_REGISTRY:
            print(f" [!] Skipping unknown design '{design_name}' (not in DESIGN_REGISTRY).")
            continue
        design_cfg = DESIGN_REGISTRY[design_name]
        design_dir = INPUT_DIR / design_name

        missing = [f for f in design_cfg["files"] + design_cfg.get("support_files", []) + [design_cfg["testbench"]]
                   if not (design_dir / f).exists()]
        if missing:
            print(f" [!] Skipping '{design_name}': missing source file(s) {missing} "
                  f"under {design_dir}/. Place the clean baseline files there first.")
            continue

        print(f"\n -> Design: {design_name} "
              f"(insertable files: {design_cfg['insertable']})")

        out_dir = OUTPUT_DIR / design_name
        out_dir.mkdir(parents=True, exist_ok=True)

        category_order = list(TROJAN_CATEGORIES.keys())
        random.shuffle(category_order)  # diversify generation order across runs/designs
        for cat_name in category_order:
            print(f"\n  -> Injecting Category: {cat_name}...")
            cat_out_dir = out_dir / cat_name
            cat_out_dir.mkdir(parents=True, exist_ok=True)

            for v in range(VARIANTS_PER_CATEGORY):
                # Randomly chosen BEFORE calling the LLM (not a rotation), so the
                # output filename, the skip-if-exists check, and the actual LLM
                # call all agree on the same target for this variant. Re-running
                # the pipeline will tend to spread Trojans across different
                # modules of a multi-file design over successive variants/runs.
                target_filename = pick_target_file(design_cfg)
                out_file = cat_out_dir / f"variant_{v}_{target_filename}"
                meta_file = cat_out_dir / f"variant_{v}_{target_filename}.trigger.json"
                act_file = cat_out_dir / f"variant_{v}_{target_filename}.activation.v"

                if out_file.exists():
                    print(f"    [=] Variant {v} (target={target_filename}) already exists on disk. Skipping.")
                    # NOTE: because the target file is randomly chosen per variant,
                    # re-running this pipeline can end up creating
                    # variant_{v}_<otherFile> alongside an existing
                    # variant_{v}_<firstFile> for the same (category, v) slot --
                    # that is intentional (more module-coverage variety across
                    # runs), not a bug; it just means "variant index" is scoped
                    # per target file, not a single global slot per category.
                    continue

                infected_code, activation_task, trigger_spec = generate_and_verify_variant(
                    design_name, design_cfg, design_dir, cat_name, v, target_filename, metrics_logger
                )

                if infected_code:
                    with open(out_file, "w", encoding="utf-8") as f:
                        f.write(infected_code)
                    with open(meta_file, "w", encoding="utf-8") as f:
                        json.dump(trigger_spec, f, indent=2)
                    with open(act_file, "w", encoding="utf-8") as f:
                        f.write(activation_task)
                    print(f"    [\u2713] Successfully saved: {out_file}")
                    print(f"          + trigger spec: {meta_file}")
                    print(f"          + activation task: {act_file}")

    print(f"\n{'='*70}")
    print("[*] Pipeline complete.")
    print(f"[*] Metrics written to: {REPORTS_DIR}/rtl_trojan_metrics.{{csv,json}}")
    print(f"{'='*70}\n")


if __name__ == "__main__":
    run_dataset_pipeline()
