#!/usr/bin/env python3
"""
02_json_to_pyg.py
==========================================
Run from the PROJECT ROOT:
    python detection/build_graphs/02_json_to_pyg.py

Converts every Yosys JSON netlist produced by 01_synthesize.py into a
PyTorch Geometric Data object and saves the complete dataset as:
    detection/graphs/dataset.pt          <- list of all Data objects
    detection/graphs/dataset_stats.csv   <- per-graph metadata
    detection/graphs/node_vocab.json     <- cell-type → index mapping

Each Data object has:
    x          : [N, F]  node feature matrix
    edge_index : [2, E]  directed edges (src → dst)
    edge_attr  : [E, 2]  edge features [src_port_is_output, dst_port_is_input]
    y          : [1]     graph label  (0=clean, 1=infected)
    node_y     : [N]     node label   (0=clean node, 1=trojan node)
    name       : str     circuit identifier  e.g. "infected__uart_cat1_sonnet5"
    design     : str     base design name    e.g. "uart"
    category   : str     trojan category     e.g. "cat1" (empty for clean)

Node features (F = 43 total)
-----------------------------
 [0 :40]  one-hot cell type  (40 known types + 1 UNKNOWN bucket = 41 dims)
           -- but stored as 40 dims with index 39 = UNKNOWN
 [40]     log2(output_width + 1)   -- bus width of the cell's primary output
 [41]     is_comparator            -- 1.0 if type is $eq / $ne / $lt / $gt / $ge
 [42]     is_register              -- 1.0 if type contains "dff"

Edge construction
-----------------
For each cell port marked "output" in port_directions, every bit it drives
gets an edge to every cell that reads that same bit on an "input" port.
This gives a directed data-flow graph: information flows from driver to sink.

Node labels (trojan nodes)
--------------------------
Computed by differentiating the infected netlist's cell names against the
corresponding clean netlist's cell names.  Cells present in the infected
design but absent in the clean design are labelled 1 (trojan nodes).
All other nodes are labelled 0.
"""

import sys
import json
import csv
import logging
import argparse
from pathlib import Path
from collections import defaultdict

import torch
from torch_geometric.data import Data

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_SCRIPT_DIR  = Path(__file__).resolve().parent
PROJECT_ROOT = _SCRIPT_DIR.parent.parent
NETLIST_DIR  = _SCRIPT_DIR.parent / "graphs" / "netlists"
OUT_DIR      = _SCRIPT_DIR.parent / "graphs"
DATASET_PT   = OUT_DIR / "dataset.pt"
STATS_CSV    = OUT_DIR / "dataset_stats.csv"
VOCAB_JSON   = OUT_DIR / "node_vocab.json"

# ---------------------------------------------------------------------------
# Cell-type vocabulary
# Full set enumerated by running 01_synthesize.py across all 10 designs,
# then inspecting every unique `type` field in the resulting JSON netlists.
# Sorted alphabetically so the one-hot index is stable and reproducible.
# ---------------------------------------------------------------------------
CELL_TYPES: list[str] = sorted([
    "$add",
    "$adff",
    "$adffe",
    "$and",
    "$dff",
    "$dffe",
    "$eq",
    "$ge",
    "$gt",
    "$logic_and",
    "$logic_not",
    "$logic_or",
    "$lt",
    "$meminit",
    "$memrd",
    "$memrd_v2",
    "$memwr_v2",
    "$mul",
    "$mux",
    "$ne",
    "$neg",
    "$not",
    "$or",
    "$pmux",
    "$reduce_and",
    "$reduce_bool",
    "$reduce_or",
    "$sdff",
    "$sdffce",
    "$sdffe",
    "$shl",
    "$shiftx",
    "$shift",
    "$sub",
    "$xor",
    # --- add any future types above this line ---
    "__UNKNOWN__",   # catch-all bucket; always last
])

CELL_TYPE_IDX: dict[str, int] = {t: i for i, t in enumerate(CELL_TYPES)}
N_CELL_TYPES  = len(CELL_TYPES)   # currently 37
UNKNOWN_IDX   = CELL_TYPE_IDX["__UNKNOWN__"]

# Sets used for the two binary indicator features
COMPARATOR_TYPES = {"$eq", "$ne", "$lt", "$gt", "$ge"}
REGISTER_SUBSTR  = "dff"           # matches $dff, $dffe, $adff, $sdffe, etc.

# ---------------------------------------------------------------------------
# Design → clean netlist mapping (for node-label diffing)
# ---------------------------------------------------------------------------
DESIGN_FOR_PREFIX = {
    "aes128":   "clean__aes128",
    "arbiter":  "clean__arbiter",
    "fft":      "clean__fft",
    "gemm":     "clean__gemm",
    "i2c":      "clean__i2c",
    "picorv32": "clean__picorv32",
    "sha256":   "clean__sha256",
    "spi":      "clean__spi",
    "sram":     "clean__sram",
    "uart":     "clean__uart",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ===========================================================================
# Core conversion
# ===========================================================================

def _param_width(param_str: str) -> int:
    """
    Yosys encodes parameter values as binary strings, e.g.
    '00000000000000000000000000001000' → 8.
    Returns 0 for anything that doesn't parse.
    """
    try:
        return int(param_str, 2)
    except (ValueError, TypeError):
        return 0


def _primary_output_width(cell: dict) -> int:
    """
    Return the bit-width of the cell's primary output port.
    Priority: Y > Q > (any output port).
    Falls back to parsing the WIDTH parameter, then to 1.
    """
    dirs = cell.get("port_directions", {})
    conns = cell.get("connections", {})

    for preferred in ("Y", "Q"):
        if preferred in dirs and dirs[preferred] == "output":
            return len(conns.get(preferred, [1]))

    # any output port
    for port, direction in dirs.items():
        if direction == "output":
            return len(conns.get(port, [1]))

    # fall back to WIDTH parameter
    params = cell.get("parameters", {})
    for key in ("WIDTH", "Y_WIDTH", "A_WIDTH"):
        if key in params:
            w = _param_width(params[key])
            if w > 0:
                return w

    return 1


def cell_to_features(cell: dict) -> list[float]:
    """
    Convert one Yosys cell dict to a flat float feature vector of length
    N_CELL_TYPES + 3.

    Layout:
      [0 : N_CELL_TYPES]  one-hot cell type
      [N_CELL_TYPES]      log2(output_width + 1)
      [N_CELL_TYPES + 1]  is_comparator
      [N_CELL_TYPES + 2]  is_register
    """
    raw_type = cell["type"]
    # Yosys sometimes prefixes with backslash for user-defined modules
    norm_type = raw_type.lstrip("\\").lower()
    # Match by prefix so '$sdffce' still hits '$sdffce' exactly, while
    # an unseen variant like '$sdffwe' would fall through to UNKNOWN
    idx = CELL_TYPE_IDX.get(norm_type, UNKNOWN_IDX)

    onehot = [0.0] * N_CELL_TYPES
    onehot[idx] = 1.0

    out_w          = _primary_output_width(cell)
    log_width      = float(out_w.bit_length())          # ≈ log2(w+1)
    is_comparator  = float(norm_type in COMPARATOR_TYPES)
    is_register    = float(REGISTER_SUBSTR in norm_type)

    return onehot + [log_width, is_comparator, is_register]


def json_netlist_to_data(json_path: Path,
                         graph_label: int,
                         clean_cell_names: set[str] | None,
                         name: str,
                         design: str,
                         category: str) -> Data | None:
    """
    Load one Yosys JSON netlist and return a PyG Data object.

    json_path         : path to the .json file
    graph_label       : 0 = clean, 1 = infected
    clean_cell_names  : set of cell names from the matching clean netlist,
                        used for node-level trojan labelling.
                        Pass None for clean circuits (all nodes labelled 0).
    name              : circuit identifier string
    design            : base design name
    category          : trojan category string ('cat1', ...) or ''
    """
    try:
        with open(json_path) as f:
            netlist = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("  Cannot read %s: %s", json_path.name, exc)
        return None

    modules = netlist.get("modules", {})
    if not modules:
        log.warning("  %s: no modules in JSON", json_path.name)
        return None

    # After 'flatten' there is exactly one module; take it.
    module = list(modules.values())[0]
    cells  = module.get("cells", {})

    if not cells:
        log.warning("  %s: module has no cells (empty design?)", json_path.name)
        return None

    cell_names = list(cells.keys())
    n_nodes    = len(cell_names)
    cell_idx   = {name_: i for i, name_ in enumerate(cell_names)}

    # ------------------------------------------------------------------
    # Node features
    # ------------------------------------------------------------------
    x_rows = [cell_to_features(cells[cn]) for cn in cell_names]
    x = torch.tensor(x_rows, dtype=torch.float)   # [N, F]

    # ------------------------------------------------------------------
    # Node labels  (0 = clean node, 1 = trojan node)
    # ------------------------------------------------------------------
    if clean_cell_names is None:
        # This is the clean circuit — every node is clean
        node_y = torch.zeros(n_nodes, dtype=torch.long)
    else:
        node_y = torch.tensor(
            [0 if cn in clean_cell_names else 1 for cn in cell_names],
            dtype=torch.long,
        )

    # ------------------------------------------------------------------
    # Edges  (directed data-flow: driver output → sink input)
    # Strategy:
    #   1. Build a map: bit_id → list of (cell_idx, port, direction)
    #   2. For every bit driven by an output port, add edges to all
    #      cells that read that bit on an input port.
    # This correctly handles multi-bit buses: a 32-bit Y port adds edges
    # for each of its 32 bit IDs individually (most will be shared).
    # We deduplicate (src, dst) pairs at the end.
    # ------------------------------------------------------------------
    # bit_id → [(cell_node_index, port_name, direction), ...]
    bit_drivers: dict[int, list[int]] = defaultdict(list)   # bit → [node_idx]
    bit_sinks:   dict[int, list[int]] = defaultdict(list)   # bit → [node_idx]

    for cn, cell in cells.items():
        ni = cell_idx[cn]
        dirs  = cell.get("port_directions", {})
        conns = cell.get("connections", {})
        for port, bits in conns.items():
            direction = dirs.get(port, "input")   # default to input if unspecified
            for bit in bits:
                if not isinstance(bit, int):
                    continue   # 'x' / 'z' constants — skip
                if direction == "output":
                    bit_drivers[bit].append(ni)
                else:
                    bit_sinks[bit].append(ni)

    edge_src: list[int] = []
    edge_dst: list[int] = []
    seen_edges: set[tuple[int, int]] = set()

    for bit, driver_nodes in bit_drivers.items():
        for sink_node in bit_sinks.get(bit, []):
            for drv in driver_nodes:
                if drv == sink_node:
                    continue   # no self-loops
                key = (drv, sink_node)
                if key not in seen_edges:
                    seen_edges.add(key)
                    edge_src.append(drv)
                    edge_dst.append(sink_node)

    if edge_src:
        edge_index = torch.tensor([edge_src, edge_dst], dtype=torch.long)
    else:
        edge_index = torch.zeros((2, 0), dtype=torch.long)

    # ------------------------------------------------------------------
    # Assemble the Data object
    # ------------------------------------------------------------------
    data = Data(
        x          = x,
        edge_index = edge_index,
        y          = torch.tensor([graph_label], dtype=torch.long),
        node_y     = node_y,
        name       = name,
        design     = design,
        category   = category,
    )
    return data


def load_clean_cell_names(json_path: Path) -> set[str] | None:
    """Return the set of cell names from a clean netlist JSON, or None on error."""
    try:
        with open(json_path) as f:
            netlist = json.load(f)
        module = list(netlist["modules"].values())[0]
        return set(module.get("cells", {}).keys())
    except Exception as exc:
        log.warning("  Cannot load clean netlist %s: %s", json_path.name, exc)
        return None


def infer_design_and_category(stem: str) -> tuple[str, str]:
    """
    'infected__uart_cat1_sonnet5' → ('uart', 'cat1')
    'clean__uart'                 → ('uart', '')
    """
    if stem.startswith("clean__"):
        design = stem[len("clean__"):]
        return design, ""

    # infected__<design>_<cat>_<model>
    inner = stem[len("infected__"):]   # 'uart_cat1_sonnet5'
    # find which design prefix matches
    for design in sorted(DESIGN_FOR_PREFIX.keys(), key=len, reverse=True):
        if inner == design or inner.startswith(design + "_"):
            rest = inner[len(design):].lstrip("_")  # 'cat1_sonnet5'
            # category is the first underscore-segment starting with 'cat'
            parts = rest.split("_")
            category = next((p for p in parts if p.startswith("cat")), "")
            return design, category

    return "unknown", ""


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Convert Yosys JSON netlists → PyTorch Geometric dataset."
    )
    parser.add_argument(
        "--netlist-dir", type=Path, default=NETLIST_DIR,
        help=f"Directory containing Yosys JSON netlists (default: {NETLIST_DIR})",
    )
    parser.add_argument(
        "--out-dir", type=Path, default=OUT_DIR,
        help=f"Output directory for dataset.pt and stats (default: {OUT_DIR})",
    )
    parser.add_argument(
        "--skip-node-labels", action="store_true",
        help="Skip the clean-vs-infected diff for node labels (faster, graph-level only).",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if not args.netlist_dir.is_dir():
        log.error("Netlist directory not found: %s", args.netlist_dir)
        log.error("Run 01_synthesize.py first.")
        sys.exit(1)

    args.out_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Discover all JSON files and partition into clean / infected
    # ------------------------------------------------------------------
    all_jsons = sorted(args.netlist_dir.glob("*.json"))
    if not all_jsons:
        log.error("No JSON files found in %s", args.netlist_dir)
        sys.exit(1)

    clean_jsons    = [p for p in all_jsons if p.stem.startswith("clean__")]
    infected_jsons = [p for p in all_jsons if p.stem.startswith("infected__")]

    log.info("Found %d clean + %d infected netlists (%d total)",
             len(clean_jsons), len(infected_jsons), len(all_jsons))

    # Pre-load clean cell name sets for node labelling
    clean_cells_by_design: dict[str, set[str]] = {}
    if not args.skip_node_labels:
        log.info("Loading clean netlists for node-label diffing ...")
        for jp in clean_jsons:
            design, _ = infer_design_and_category(jp.stem)
            cell_names = load_clean_cell_names(jp)
            if cell_names is not None:
                clean_cells_by_design[design] = cell_names
                log.debug("  %s: %d clean cells", design, len(cell_names))

    # ------------------------------------------------------------------
    # Convert every netlist
    # ------------------------------------------------------------------
    dataset:    list[Data] = []
    stats_rows: list[dict] = []
    n_ok = n_fail = 0

    total = len(all_jsons)
    for idx, jp in enumerate(all_jsons, 1):
        stem            = jp.stem
        is_infected     = stem.startswith("infected__")
        graph_label     = 1 if is_infected else 0
        design, category = infer_design_and_category(stem)

        # Retrieve clean cell names for node labelling
        if is_infected and not args.skip_node_labels:
            clean_names = clean_cells_by_design.get(design)
            if clean_names is None:
                log.warning(
                    "  [%d/%d] No clean reference for design '%s'; "
                    "node labels will all be 0.", idx, total, design
                )
        else:
            clean_names = None   # clean circuits or skip-node-labels mode

        log.info("[%3d/%d] converting  %s", idx, total, stem)

        data = json_netlist_to_data(
            json_path         = jp,
            graph_label       = graph_label,
            clean_cell_names  = clean_names,
            name              = stem,
            design            = design,
            category          = category,
        )

        if data is None:
            n_fail += 1
            stats_rows.append({
                "name": stem, "design": design, "category": category,
                "is_infected": int(is_infected),
                "n_nodes": 0, "n_edges": 0,
                "n_trojan_nodes": 0, "status": "fail",
            })
            continue

        n_trojan = int(data.node_y.sum().item()) if is_infected else 0
        log.info("       → %d nodes, %d edges, %d trojan nodes",
                 data.x.size(0), data.edge_index.size(1), n_trojan)

        dataset.append(data)
        n_ok += 1
        stats_rows.append({
            "name":           stem,
            "design":         design,
            "category":       category,
            "is_infected":    int(is_infected),
            "n_nodes":        data.x.size(0),
            "n_edges":        data.edge_index.size(1),
            "n_trojan_nodes": n_trojan,
            "status":         "ok",
        })

    # ------------------------------------------------------------------
    # Save dataset
    # ------------------------------------------------------------------
    dataset_path = args.out_dir / "dataset.pt"
    torch.save(dataset, dataset_path, pickle_protocol=4)
    log.info("Dataset saved → %s  (%d graphs)", dataset_path, len(dataset))

    # ------------------------------------------------------------------
    # Save stats CSV
    # ------------------------------------------------------------------
    stats_path = args.out_dir / "dataset_stats.csv"
    with open(stats_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=[
            "name", "design", "category", "is_infected",
            "n_nodes", "n_edges", "n_trojan_nodes", "status",
        ])
        writer.writeheader()
        writer.writerows(stats_rows)
    log.info("Stats CSV → %s", stats_path)

    # ------------------------------------------------------------------
    # Save node vocabulary (for reproducibility / inspection)
    # ------------------------------------------------------------------
    vocab_path = args.out_dir / "node_vocab.json"
    with open(vocab_path, "w") as fh:
        json.dump({
            "cell_types":   CELL_TYPES,
            "cell_type_idx": CELL_TYPE_IDX,
            "n_cell_types": N_CELL_TYPES,
            "node_feature_dim": N_CELL_TYPES + 3,
            "feature_layout": {
                "0_to_{N-1}": "one-hot cell type (N = n_cell_types)",
                "N+0":        "log2(primary_output_width + 1)",
                "N+1":        "is_comparator  ($eq $ne $lt $gt $ge)",
                "N+2":        "is_register    (type contains 'dff')",
            },
        }, fh, indent=2)
    log.info("Node vocab → %s", vocab_path)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    log.info("=" * 70)
    log.info("Done:  %d OK  |  %d failed", n_ok, n_fail)
    log.info("Node feature dim : %d", N_CELL_TYPES + 3)

    clean_graphs    = [d for d in dataset if d.y.item() == 0]
    infected_graphs = [d for d in dataset if d.y.item() == 1]
    log.info("Clean graphs     : %d", len(clean_graphs))
    log.info("Infected graphs  : %d", len(infected_graphs))

    if dataset:
        all_nodes  = sum(d.x.size(0) for d in dataset)
        all_edges  = sum(d.edge_index.size(1) for d in dataset)
        trojan_nodes = sum(int(d.node_y.sum()) for d in infected_graphs)
        clean_nodes  = sum(d.x.size(0) for d in infected_graphs) - trojan_nodes
        log.info("Total nodes      : %d  (across all graphs)", all_nodes)
        log.info("Total edges      : %d", all_edges)
        if infected_graphs:
            log.info("Trojan nodes     : %d / %d  (%.2f%% of infected-graph nodes)",
                     trojan_nodes, clean_nodes + trojan_nodes,
                     100.0 * trojan_nodes / max(clean_nodes + trojan_nodes, 1))

    log.info("=" * 70)

    # Per-category breakdown
    from collections import Counter
    cat_counts = Counter(d.category for d in infected_graphs)
    log.info("Infected graphs by category:")
    for cat in sorted(cat_counts):
        log.info("  %-8s : %d", cat or "(none)", cat_counts[cat])

    log.info("=" * 70)
    sys.exit(0 if n_fail == 0 else 1)


if __name__ == "__main__":
    main()
