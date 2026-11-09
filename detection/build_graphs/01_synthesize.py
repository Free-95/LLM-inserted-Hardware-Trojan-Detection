#!/usr/bin/env python3
"""
01_synthesize.py
==========================================================================
Run from the PROJECT ROOT:
    python detection/build_graphs/01_synthesize.py

Synthesizes every clean baseline and every infected variant to a Yosys
JSON netlist (RTL-level, pre-technology-mapping). The resulting JSON files
are the input to 02_json_to_pyg.py which builds PyTorch Geometric Data
objects.

Output layout
-------------
detection/graphs/netlists/
    clean__uart.json
    clean__spi.json
    ...
    infected__uart_cat1_sonnet5.json
    infected__uart_cat2_sonnet5.json
    ...
detection/graphs/synthesis_manifest.csv    <- one row per circuit

Synthesis mode
--------------
Default ("rtl"): proc → opt → flatten → opt → write_json
  - No liberty file needed.
  - Node types are Yosys internal cells ($eq, $mux, $_DFF_P_, etc.) --
    design-agnostic, same vocabulary across all 10 designs.
  - Recommended for the GNN.

Optional ("gate"): full synth + abc -liberty sky130.lib → write_json
  - Requires SKY130_LIBERTY_PATH env var or --liberty flag.
  - Useful for a separate gate-level ablation study.
  - Run with:  --mode gate --liberty /path/to/sky130_fd_sc_hd__tt_025C_1v80.lib

Run Commands
------------
# Standard RTL-level synthesis (recommended, no liberty file needed)
python detection/build_graphs/01_synthesize.py

# Gate-level (optional ablation, needs sky130 liberty)
python detection/build_graphs/01_synthesize.py --mode gate --liberty /path/to/sky130_fd_sc_hd__tt_025C_1v80.lib

# Specific designs only
python detection/build_graphs/01_synthesize.py --designs uart spi aes128

# Re-run failed ones without redoing the already-cached ones
python detection/build_graphs/01_synthesize.py --verbose
"""

import sys
import os
import json
import csv
import argparse
import logging
import subprocess
import tempfile
import shutil
import fnmatch
from pathlib import Path
from datetime import datetime

# ---------------------------------------------------------------------------
# Paths  (relative to project root)
# ---------------------------------------------------------------------------
_SCRIPT_DIR  = Path(__file__).resolve().parent          # detection/build_graphs/
PROJECT_ROOT = _SCRIPT_DIR.parent.parent                # project root
BENCH_DIR    = PROJECT_ROOT / "benchmarks"
CLEAN_DIR    = BENCH_DIR   / "clean_baseline"
INFECTED_DIR = BENCH_DIR   / "infected_rtl"
OUT_DIR      = _SCRIPT_DIR.parent / "graphs" / "netlists"
MANIFEST_CSV = _SCRIPT_DIR.parent / "graphs" / "synthesis_manifest.csv"

# ---------------------------------------------------------------------------
# Design registry
# Every entry:
#   "sources"    : RTL files to synthesize (relative to that design's directory)
#   "top"        : top module name for `hierarchy -top`
#   "extra_read" : extra read_verilog flags beyond -sv (rarely needed)
# ---------------------------------------------------------------------------
DESIGN_REGISTRY = {
    "uart": {
        "sources": ["impl_top.v", "uart_rx.v", "uart_tx.v"],
        "top":     "impl_top",
    },
    "spi": {
        # spi_defines.v uses `define macros; it must be listed first so
        # Yosys sees the macros before reading the files that use them.
        "sources": ["spi_defines.v", "spi_top.v", "spi_shift.v", "spi_clgen.v"],
        "top":     "spi_top",
    },
    "i2c": {
        "sources": ["i2c_master_bit_ctrl.v", "i2c_master_byte_ctrl.v",
                    "i2c_master_top.v"],
        "top":     "i2c_master_top",
    },
    "aes128": {
        "sources": ["table.v", "round.v", "aes_128.v"],
        "top":     "aes_128",
    },
    "sha256": {
        "sources": ["sha256_k_constants.v", "sha256_w_mem.v", "sha256_core.v"],
        "top":     "sha256_core",
    },
    "sram": {
        "sources": ["SRAM_32x128_1rw.v", "wb_sram_controller.v"],
        "top":     "wb_sram_controller",
    },
    "arbiter": {
        "sources": ["wb_arbiter_2m1s.v"],
        "top":     "wb_arbiter_2m1s",
    },
    "fft": {
        # fft_8point.sv is SystemVerilog; -sv covers the whole batch
        "sources": [
            "rca_16bit.v",
            "vedic_multiplier_q8_8.v",
            "cpx_mad.v",
            "cordic_sincos.v",
            "cordic_twiddle_generator.v",
            "butterfly_2point.v",
            "fft_8point.sv"
        ],
        "top": "fft_8point",
    },
    "gemm": {
        "sources": ["systolic_pe.v", "systolic_array_gemm.v"],
        "top":     "systolic_array_gemm",
    },
    "picorv32": {
        "sources": ["picorv32.v"],
        "top":     "picorv32",
    },
}

# Files to skip even if they appear in an infected variant directory.
# Glob patterns matched against the bare filename.
NON_SYNTH_GLOBS = [
    "tb_*.v", "tb_*.sv",
    "testbench.v", "testbench.sv",
    "activation_testbench.v",
    "*_slave_model.v", "*_master_model.v", "wb_master_model.v",
    "*.py", "*.hex", "*.sh", "*.txt", "*.md", "*.json",
    "*.csv", "*.ld", "*.S", "*.c", "*.bin", "*.elf",
]

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ===========================================================================
# Helpers
# ===========================================================================

def infer_design(variant_dir_name: str):
    """
    Extract the design key from an infected-variant directory name.
    'uart_cat1_sonnet5'    → 'uart'
    'aes128_cat2_sonnet5'  → 'aes128'
    'picorv32_cat3_sonnet5'→ 'picorv32'
    Longest-match wins to handle designs like 'sha256' vs 'sha'.
    Returns None if no design matches.
    """
    for name in sorted(DESIGN_REGISTRY.keys(), key=len, reverse=True):
        if variant_dir_name == name or variant_dir_name.startswith(name + "_"):
            return name
    return None


def should_skip(filename: str) -> bool:
    """Return True if this file should NOT be passed to Yosys."""
    for pat in NON_SYNTH_GLOBS:
        if fnmatch.fnmatch(filename, pat):
            return True
    return False


# Designs that contain SV constructs Yosys cannot parse natively even with
# -sv (specifically: multi-dimensional packed array ports, e.g. [0:7][31:0]).
# These are pre-converted to plain Verilog via sv2v before Yosys sees them.
SV2V_REQUIRED = {"fft"}
 
 
def sv2v_available() -> bool:
    """Return True if the sv2v binary is on PATH."""
    return shutil.which("sv2v") is not None
 
 
def run_sv2v(sv_files: list[Path], plain_v_files: list[Path],
             out_dir: Path, label: str, timeout: int = 60) -> list[Path]:
    """
    Convert every file in sv_files from SystemVerilog to plain Verilog using
    sv2v, writing converted files into out_dir.  Returns a new combined file
    list: converted SV files are replaced by their .v counterparts; files in
    plain_v_files are returned unchanged (sv2v is not run on them).
 
    Raises RuntimeError if sv2v fails or produces no output.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    result_paths = list(plain_v_files)  # start with the already-plain files

    for sv_path in sv_files:
        out_path = out_dir / (sv_path.stem + "_sv2v.v")
        cmd = ["sv2v", "--write", str(out_path), str(sv_path)]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"sv2v timed out on {sv_path.name}")
        except FileNotFoundError:
            raise RuntimeError(
                "sv2v not found. Install from https://github.com/zachjs/sv2v/releases"
            )
 
        if res.returncode != 0 or not out_path.exists() or out_path.stat().st_size == 0:
            err = (res.stderr or res.stdout or "unknown error").strip().splitlines()[0]
            raise RuntimeError(f"sv2v failed on {sv_path.name}: {err}")
 
        log.debug("  sv2v: %s → %s (%d bytes)",
                  sv_path.name, out_path.name, out_path.stat().st_size)
        result_paths.append(out_path)
 
    return result_paths


def load_trigger_spec(infected_dir: Path) -> dict | None:
    """
    Load trigger_spec.json from an infected variant directory.
    Returns the parsed dict, or None if not found.
    """
    # trigger_spec.json lives either directly in the variant dir
    # or in benchmarks/trojan_reports/<variant_name>/
    candidates = [
        infected_dir / "trigger_spec.json",
        PROJECT_ROOT / "benchmarks" / "trojan_reports" /
            infected_dir.name / "trigger_spec.json",
    ]
    for p in candidates:
        if p.exists():
            try:
                with open(p) as f:
                    return json.load(f)
            except Exception:
                return None
    return None
    
    
def build_yosys_script(src_dir: Path, design: str, out_json: Path,
                       mode: str = "rtl", liberty: Path = None,
                       sv2v_tmp_dir: Path = None,
                       clean_dir: Path = None,
                       target_file: str = None) -> str:
    """
    Return the Yosys command-string for one synthesis run.

    src_dir      : directory that contains the RTL files for this circuit
                   (clean baseline dir for clean circuits;
                    infected variant dir for infected circuits)
    design       : key into DESIGN_REGISTRY
    out_json     : where to write the JSON netlist
    mode         : 'rtl' (default, pre-tech-map) or 'gate' (full synth + abc)
    liberty      : path to .lib for 'gate' mode; ignored in 'rtl' mode
    sv2v_tmp_dir : if set, pre-converted SV→V files land here (FFT only)
    clean_dir    : for infected circuits, the clean baseline directory.
                   When provided alongside target_file, all files EXCEPT
                   target_file are read from clean_dir so their absolute
                   paths are identical to the clean synthesis run.  This
                   is essential: Yosys embeds the source file path in
                   every flattened cell name, so reading unmodified files
                   from a different directory gives them different cell
                   names than the clean netlist, making the name-based
                   trojan-node diff completely unreliable.
    target_file  : filename of the single modified file (from trigger_spec
                   target_file field).  Read from src_dir; all others from
                   clean_dir.
    """
    reg     = DESIGN_REGISTRY[design]
    sources = reg["sources"]
    top     = reg["top"]

    # Build the file path list.
    # Rule: if clean_dir + target_file are both provided (infected circuit),
    # read target_file from src_dir and everything else from clean_dir.
    # Otherwise read everything from src_dir (clean circuit case).
    file_paths = []
    missing    = []

    for fname in sources:
        if clean_dir is not None and target_file is not None:
            # Infected circuit: only the trojan file comes from src_dir
            if fname == target_file:
                p = src_dir / fname
            else:
                p = clean_dir / fname
        else:
            p = src_dir / fname

        if p.exists():
            file_paths.append(p)
        else:
            missing.append(f"{fname} (from {p.parent.name})")

    if missing:
        log.warning("  [warn] %s: missing source file(s): %s",
                    design, ", ".join(missing))
    if not file_paths:
        raise FileNotFoundError(f"No source files found for {design} in {src_dir}")

    # --- sv2v pre-processing for designs with 2D packed array ports ---
    # Yosys's -sv frontend rejects multi-dimensional packed arrays
    # (e.g. `input [0:7][31:0] data`). sv2v flattens them to 1D Verilog.
    if design in SV2V_REQUIRED:
        if not sv2v_available():
            raise RuntimeError(
                f"Design '{design}' requires sv2v to handle 2D packed array ports, "
                "but sv2v was not found on PATH.\n"
                "  Install: wget https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.zip\n"
                "           unzip sv2v-Linux.zip && sudo mv sv2v /usr/local/bin/"
            )
        sv_paths    = [p for p in file_paths if p.suffix == ".sv"]
        plain_paths = [p for p in file_paths if p.suffix != ".sv"]

        if sv2v_tmp_dir is None:
            sv2v_tmp_dir = Path(tempfile.mkdtemp(prefix="sv2v_"))

        file_paths = run_sv2v(sv_paths, plain_paths,
                              sv2v_tmp_dir / design, label=design)
        # After conversion everything is plain Verilog — no -sv flag needed
        sv_flag = ""
    else:
        sv_flag = "-sv" if any(p.suffix == ".sv" for p in file_paths) else ""

    # Include path: for infected circuits point to the clean dir so that
    # `include "spi_defines.v" etc. resolve from the same path as clean.
    # For clean circuits (clean_dir is None), point to src_dir.
    inc_dir  = clean_dir if clean_dir is not None else src_dir
    inc_flag = f"-I{inc_dir}"

    files_str = " ".join(f'"{p}"' for p in file_paths)
    
    if mode == "rtl":
        synth_cmds = "proc; opt; flatten; opt"
    else:  # gate
        if liberty is None:
            raise ValueError("gate mode requires a liberty file (--liberty)")
        synth_cmds = (
            f"synth -top {top};\n"
            f'dfflibmap -liberty "{liberty}";\n'
            f'abc -liberty "{liberty}"'
        )

    return (
        f"read_verilog {sv_flag} {inc_flag} {files_str}\n"
        f"hierarchy -check -top {top}\n"
        f"{synth_cmds}\n"
        f'write_json "{out_json}"\n'
    )


def run_yosys(yosys_script: str, label: str, timeout: int = 180):
    """
    Execute a Yosys script string.  Returns (success: bool, stderr: str).
    """
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ys",
                                     delete=False, prefix="synth_") as fh:
        fh.write(yosys_script)
        script_path = fh.name

    try:
        result = subprocess.run(
            ["yosys", "-q", "-s", script_path],
            capture_output=True, text=True, timeout=timeout,
        )
        success = (result.returncode == 0
                   and "ERROR" not in result.stderr.upper()
                   and "ERROR" not in result.stdout.upper())
        if not success:
            combined = result.stdout + result.stderr
            # Surface the first ERROR line
            first_err = next(
                (ln for ln in combined.splitlines() if "ERROR" in ln.upper()),
                "(no ERROR line found)"
            )
            log.debug("  Yosys stderr for %s: %s", label, first_err)
        return success, result.stderr
    except subprocess.TimeoutExpired:
        log.warning("  [timeout] %s exceeded %ds", label, timeout)
        return False, "TIMEOUT"
    except FileNotFoundError:
        log.error("yosys binary not found. Install Yosys (apt install yosys).")
        sys.exit(1)
    finally:
        Path(script_path).unlink(missing_ok=True)


def synthesize_one(src_dir: Path, design: str, out_path: Path,
                   mode: str, liberty: Path, timeout: int,
                   sv2v_tmp_dir: Path = None,
                   is_infected: bool = False) -> bool:
    """
    Full flow for one circuit: (optional sv2v) → build script → run Yosys
    → validate output.  Returns True on success.

    For infected circuits (is_infected=True), loads trigger_spec.json from
    src_dir to find the single modified file, then reads all other source
    files from the clean baseline directory so their absolute paths are
    identical to the clean synthesis run.  This keeps cell names consistent
    for the name-based trojan-node diff in 02_json_to_pyg.py.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)

    clean_dir   = None
    target_file = None

    if is_infected:
        spec = load_trigger_spec(src_dir)
        if spec and spec.get("target_file"):
            target_file = spec["target_file"]
            clean_dir   = CLEAN_DIR / design
            if not clean_dir.is_dir():
                log.warning("  [warn] Clean baseline dir not found: %s; "
                            "falling back to infected-dir-only synthesis "
                            "(node labels will be unreliable).", clean_dir)
                clean_dir = target_file = None
            else:
                log.debug("  trojan file: %s  (all others from clean baseline)",
                          target_file)
        else:
            log.warning("  [warn] No trigger_spec.json found in %s; "
                        "falling back to infected-dir-only synthesis "
                        "(node labels will be unreliable).", src_dir.name)

    try:
        script = build_yosys_script(src_dir, design, out_path, mode, liberty,
                                    sv2v_tmp_dir=sv2v_tmp_dir,
                                    clean_dir=clean_dir,
                                    target_file=target_file)
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        log.warning("  [skip] %s: %s", design, exc)
        return False

    success, stderr = run_yosys(script, str(out_path.name), timeout)

    if success and out_path.exists():
        # Quick sanity check: JSON must contain at least one module
        try:
            with open(out_path) as f:
                data = json.load(f)
            if not data.get("modules"):
                log.warning("  [empty] %s: JSON has no modules", out_path.name)
                out_path.unlink(missing_ok=True)
                return False
        except json.JSONDecodeError:
            log.warning("  [corrupt] %s: invalid JSON", out_path.name)
            out_path.unlink(missing_ok=True)
            return False
        return True
    else:
        out_path.unlink(missing_ok=True)
        return False


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Synthesize all clean + infected RTL to Yosys JSON netlists."
    )
    parser.add_argument(
        "--mode", choices=["rtl", "gate"], default="rtl",
        help="rtl: pre-tech-map JSON (default, no liberty needed). "
             "gate: full synth + abc (requires --liberty).",
    )
    parser.add_argument(
        "--liberty", type=Path, default=None,
        metavar="PATH",
        help="Path to sky130 .lib file (required for --mode gate).",
    )
    parser.add_argument(
        "--timeout", type=int, default=180,
        help="Per-design Yosys timeout in seconds (default: 180).",
    )
    parser.add_argument(
        "--designs", nargs="+", default=None,
        metavar="DESIGN",
        help="Synthesize only these design names (default: all 10).",
    )
    parser.add_argument(
        "--skip-clean", action="store_true",
        help="Skip clean baselines (re-run infected only).",
    )
    parser.add_argument(
        "--skip-infected", action="store_true",
        help="Skip infected variants (re-run clean only).",
    )
    parser.add_argument(
        "--overwrite", action="store_true",
        help="Re-synthesize even if the output JSON already exists.",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Show Yosys stderr on failure.",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.mode == "gate" and args.liberty is None:
        # Fall back to env var
        liberty_env = os.environ.get("SKY130_LIBERTY_PATH")
        if liberty_env:
            args.liberty = Path(liberty_env)
        else:
            parser.error("--mode gate requires --liberty <path/to/sky130.lib> "
                         "or SKY130_LIBERTY_PATH env var.")

    if not shutil.which("yosys"):
        log.error("yosys not found on PATH. Install with: apt install yosys")
        sys.exit(1)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Decide which designs to process
    target_designs = set(args.designs) if args.designs else set(DESIGN_REGISTRY.keys())
    unknown = target_designs - set(DESIGN_REGISTRY.keys())
    if unknown:
        log.error("Unknown design(s): %s.  Valid: %s",
                  unknown, sorted(DESIGN_REGISTRY.keys()))
        sys.exit(1)

    # Check sv2v for designs that need it
    needs_sv2v = target_designs & SV2V_REQUIRED
    if needs_sv2v and not sv2v_available():
        log.warning(
            "sv2v not found on PATH. Design(s) %s will be skipped.\n"
            "  Install sv2v: wget https://github.com/zachjs/sv2v/releases/"
            "latest/download/sv2v-Linux.zip\n"
            "                unzip sv2v-Linux.zip && sudo mv sv2v /usr/local/bin/",
            sorted(needs_sv2v),
        )
    elif needs_sv2v:
        log.info("sv2v found — will pre-convert 2D packed array ports for: %s",
                 sorted(needs_sv2v))

    # Shared temp directory for sv2v-converted files (cleaned up at the end)
    sv2v_tmp = Path(tempfile.mkdtemp(prefix="sv2v_synth_"))
    
    # -----------------------------------------------------------------------
    # Build the full job list
    # -----------------------------------------------------------------------
    jobs = []  # list of (src_dir, design, out_path, label, is_infected)

    # -- Clean baselines --
    if not args.skip_clean:
        for design in sorted(target_designs):
            src_dir  = CLEAN_DIR / design
            if not src_dir.is_dir():
                log.warning("[clean] Directory not found, skipping: %s", src_dir)
                continue
            out_path = OUT_DIR / f"clean__{design}.json"
            jobs.append((src_dir, design, out_path, f"clean__{design}", False))

    # -- Infected variants --
    if not args.skip_infected:
        if not INFECTED_DIR.is_dir():
            log.error("infected_rtl directory not found: %s", INFECTED_DIR)
            sys.exit(1)

        for variant_dir in sorted(INFECTED_DIR.iterdir()):
            if not variant_dir.is_dir():
                continue
            design = infer_design(variant_dir.name)
            if design is None:
                log.warning("[infected] Cannot infer design from '%s', skipping.",
                            variant_dir.name)
                continue
            if design not in target_designs:
                continue
            out_path = OUT_DIR / f"infected__{variant_dir.name}.json"
            jobs.append((variant_dir, design, out_path,
                         f"infected__{variant_dir.name}", True))

    if not jobs:
        log.info("No jobs to run (check --designs / --skip flags).")
        sys.exit(0)

    # -----------------------------------------------------------------------
    # Run all jobs
    # -----------------------------------------------------------------------
    log.info("=" * 70)
    log.info("Synthesis mode : %s", args.mode.upper())
    log.info("Output dir     : %s", OUT_DIR)
    log.info("Total jobs     : %d", len(jobs))
    log.info("=" * 70)

    results   = []
    n_ok      = 0
    n_skip    = 0
    n_fail    = 0
    t_start   = datetime.now()

    for idx, (src_dir, design, out_path, label, is_infected) in enumerate(jobs, 1):
        prefix = f"[{idx:3d}/{len(jobs)}]"

        # Cache hit
        if out_path.exists() and not args.overwrite:
            log.info("%s CACHED  %s", prefix, label)
            results.append({
                "label": label, "design": design,
                "is_infected": int(is_infected),
                "out_json": str(out_path.relative_to(PROJECT_ROOT)),
                "status": "cached",
            })
            n_ok += 1
            continue

        log.info("%s synth    %s  (from %s)",
                 prefix, label, src_dir.relative_to(PROJECT_ROOT))

        ok = synthesize_one(src_dir, design, out_path,
                            args.mode, args.liberty, args.timeout,
                            sv2v_tmp_dir=sv2v_tmp,
                            is_infected=is_infected)
        if ok:
            # Report node/edge count for a quick sanity check
            try:
                with open(out_path) as f:
                    d = json.load(f)
                mod = list(d["modules"].values())[0]
                ncells = len(mod.get("cells", {}))
                nnets  = len(mod.get("netnames", {}))
                log.info("       OK  → %d cells, %d nets", ncells, nnets)
            except Exception:
                log.info("       OK")
            n_ok += 1
            status = "ok"
        else:
            log.warning("       FAIL  %s", label)
            n_fail += 1
            status = "fail"

        results.append({
            "label":       label,
            "design":      design,
            "is_infected": int(is_infected),
            "out_json":    str(out_path.relative_to(PROJECT_ROOT)) if ok else "",
            "status":      status,
        })

    elapsed = (datetime.now() - t_start).total_seconds()

    # -----------------------------------------------------------------------
    # Write manifest CSV
    # -----------------------------------------------------------------------
    MANIFEST_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_CSV, "w", newline="") as fh:
        writer = csv.DictWriter(
            fh, fieldnames=["label", "design", "is_infected", "out_json", "status"]
        )
        writer.writeheader()
        writer.writerows(results)
    log.info("Manifest written → %s", MANIFEST_CSV.relative_to(PROJECT_ROOT))

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    log.info("=" * 70)
    log.info("Done in %.1fs:  %d OK  |  %d FAILED  |  %d cached/skipped",
             elapsed, n_ok, n_fail, n_skip)

    if n_fail > 0:
        log.info("Failed circuits:")
        for r in results:
            if r["status"] == "fail":
                log.info("  - %s", r["label"])
        log.info("Re-run with --verbose for detailed Yosys stderr.")

    # Per-design summary (useful for spotting a whole design that broke)
    log.info("-" * 70)
    log.info("%-30s  %s", "Design", "OK / Total")
    by_design = {}
    for r in results:
        d = r["design"]
        by_design.setdefault(d, {"ok": 0, "total": 0})
        by_design[d]["total"] += 1
        if r["status"] in ("ok", "cached"):
            by_design[d]["ok"] += 1
    for d in sorted(by_design):
        log.info("  %-28s  %d / %d",
                 d, by_design[d]["ok"], by_design[d]["total"])
    log.info("=" * 70)

    # Clean up sv2v temporary files
    shutil.rmtree(sv2v_tmp, ignore_errors=True)
    
    sys.exit(0 if n_fail == 0 else 1)


if __name__ == "__main__":
    main()
