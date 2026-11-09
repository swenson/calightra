#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Post-processor for AXI CSR transaction logs.

Reads axi_csr_transactions.log produced by the bind-module tracker
(+define+TRACK_FSM_TRANSITIONS) and outputs:
  1. Human-readable transaction log with aligned columns
  2. Per-register access frequency (read count, write count)
  3. Transaction rate over time (transactions per time window)
  4. Registers never accessed (coverage gap detection)

Usage:
    python parse_axi_csr_log.py [axi_csr_transactions.log]
"""

import argparse
import importlib.util
import os
import sys
from collections import defaultdict
from pathlib import Path


def _load_known_csrs():
    """Load CSR names from the auto-generated reg_map.py.

    Falls back to an empty list if reg_map.py is not found.
    """
    # Try to find reg_map.py relative to I3C_ROOT_DIR or script location
    candidates = []
    i3c_root = os.environ.get("I3C_ROOT_DIR")
    if i3c_root:
        candidates.append(Path(i3c_root) / "verification" / "cocotb" / "common" / "reg_map.py")
    script_dir = Path(__file__).resolve().parent
    candidates.append(script_dir.parent / "cocotb" / "common" / "reg_map.py")

    for reg_map_path in candidates:
        if reg_map_path.exists():
            spec = importlib.util.spec_from_file_location("reg_map", str(reg_map_path))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return _collect_csr_names(dict(mod.reg_map))

    print("WARNING: reg_map.py not found; coverage gap detection disabled.", file=sys.stderr)
    return []


def _collect_csr_names(d, prefix="", base=0):
    """Walk reg_map dict and collect all CSR names (matching axi_csr_tracker.sv naming)."""
    names = []
    if not isinstance(d, dict):
        return names
    sa = d.get("start_addr", base)
    for k, v in d.items():
        if not isinstance(v, dict):
            continue
        if "offset" in v and any(
            isinstance(fv, dict) and "low" in fv for fv in v.values() if isinstance(fv, dict)
        ):
            addr = sa + v["offset"]
            if addr <= 0xFFF:
                names.append(f"{prefix}{k}")
        elif any(isinstance(fv, dict) for fv in v.values() if isinstance(fv, dict)):
            new_prefix = f"{prefix}{k}." if k not in ("base_addr", "start_addr", "offset") else prefix
            names.extend(_collect_csr_names(v, new_prefix, sa))
    return names


# Auto-populated from reg_map.py (same source as the SV tracker)
KNOWN_CSRS = _load_known_csrs()


def parse_log(path):
    """Parse axi_csr_transactions.log, return list of (timestamp_str, csr_name, direction, data_hex)."""
    transactions = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 4:
                print(f"WARNING: skipping malformed line {lineno}: {line!r}", file=sys.stderr)
                continue
            ts_raw = parts[0]
            csr_name = parts[1]
            direction = parts[2]
            data_hex = parts[3]
            transactions.append((ts_raw, csr_name, direction, data_hex))
    return transactions


def parse_timestamp(ts_raw):
    """Convert raw timestamp string to a numeric value."""
    for suffix in ("fs", "ps", "ns", "us", "ms", "s"):
        if ts_raw.endswith(suffix):
            return float(ts_raw[:-len(suffix)])
    return float(ts_raw)


def print_readable_log(transactions):
    """Print aligned, human-readable transaction log."""
    print("=" * 90)
    print("AXI CSR TRANSACTION LOG")
    print("=" * 90)
    print(f"{'Timestamp':>14s} | {'CSR Name':<50s} | {'Dir':>5s} | {'Data':<10s}")
    print("-" * 90)
    for ts_raw, csr_name, direction, data_hex in transactions:
        print(f"{ts_raw:>14s} | {csr_name:<50s} | {direction:>5s} | {data_hex}")
    print(f"\nTotal transactions: {len(transactions)}")


def print_access_frequency(transactions):
    """Print per-register access frequency."""
    reads = defaultdict(int)
    writes = defaultdict(int)
    for _, csr_name, direction, _ in transactions:
        if direction == "READ":
            reads[csr_name] += 1
        else:
            writes[csr_name] += 1

    all_csrs = sorted(set(list(reads.keys()) + list(writes.keys())))

    print("\n" + "=" * 90)
    print("PER-REGISTER ACCESS FREQUENCY")
    print("=" * 90)
    print(f"  {'CSR Name':<50s} {'Reads':>8s} {'Writes':>8s} {'Total':>8s}")
    print("  " + "-" * 78)
    for csr in all_csrs:
        r = reads[csr]
        w = writes[csr]
        print(f"  {csr:<50s} {r:>8d} {w:>8d} {r+w:>8d}")
    print(f"\n  Total reads: {sum(reads.values())}, writes: {sum(writes.values())}")


def print_never_accessed(transactions):
    """Flag known CSRs that were never accessed."""
    accessed = set()
    for _, csr_name, _, _ in transactions:
        accessed.add(csr_name)

    never = [c for c in KNOWN_CSRS if c not in accessed]

    print("\n" + "=" * 90)
    print("CSR COVERAGE GAPS (never accessed)")
    print("=" * 90)
    if not never:
        print("  None — all known CSRs were accessed at least once.")
    else:
        print(f"  {len(never)} CSR(s) never accessed:")
        for csr in never:
            print(f"    {csr}")


def main():
    parser = argparse.ArgumentParser(
        description="Parse and analyze AXI CSR transaction logs.")
    parser.add_argument("logfile", nargs="?", default="axi_csr_transactions.log",
                        help="Path to axi_csr_transactions.log (default: axi_csr_transactions.log)")
    args = parser.parse_args()

    log_path = Path(args.logfile)
    if not log_path.exists():
        print(f"ERROR: {log_path} not found.", file=sys.stderr)
        sys.exit(1)

    transactions = parse_log(log_path)
    if not transactions:
        print("No transactions found in log file.")
        sys.exit(0)

    print_readable_log(transactions)
    print_access_frequency(transactions)
    print_never_accessed(transactions)


if __name__ == "__main__":
    main()
