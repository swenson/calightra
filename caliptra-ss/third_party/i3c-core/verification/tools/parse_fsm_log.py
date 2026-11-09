#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Post-processor for i3c_target_fsm state transition logs.

Reads fsm_transitions.log produced by the bind-module tracker
(+define+TRACK_FSM_TRANSITIONS) and outputs:
  1. Human-readable transition log with aligned columns
  2. Transition frequency matrix
  3. Time-in-state summary (min / max / total per state)
  4. Unexpected transition detection

The log uses numeric state IDs; this script maps them to names.

Usage:
    python parse_fsm_log.py [fsm_transitions.log]
"""

import argparse
import sys
from collections import defaultdict
from pathlib import Path

# Numeric ID -> name mapping from primary_state_e (i3c_target_fsm.sv)
STATE_NAMES = {
    0: "Idle",
    1: "RxFByteArb",
    2: "RxFByte",
    3: "CheckFByte",
    4: "TxAckFByte",
    5: "RxSByte",
    6: "RxSByteRepeated",
    7: "CheckSByte",
    8: "TxAckSByte",
    9: "RxPWriteData",
    10: "RxPWriteTbit",
    11: "TxPReadData",
    12: "TxPReadTbitCont",
    13: "TxPReadTbitEnd",
    14: "WaitRestart",
    15: "DoCCC",
    16: "DoneCCC",
    17: "DoHotJoin",
    18: "DoRstAction",
    19: "InHDRMode",
    20: "IbiDriveAddr",
    21: "IbiReadAck",
    22: "IbiSendData",
    23: "IbiTbitCont",
    24: "IbiTbitEnd",
}

VALID_STATES = set(STATE_NAMES.values())

# Expected transitions from the FSM case statement.
# A missing edge here doesn't necessarily mean a bug — it means the
# post-processor will flag it for manual review.
EXPECTED_TRANSITIONS = {
    ("Idle", "RxFByteArb"),
    ("Idle", "RxFByte"),
    ("Idle", "IbiDriveAddr"),
    ("Idle", "DoRstAction"),
    ("RxFByteArb", "CheckFByte"),
    ("RxFByteArb", "IbiReadAck"),
    ("RxFByte", "CheckFByte"),
    ("CheckFByte", "TxAckFByte"),
    ("CheckFByte", "WaitRestart"),
    ("CheckFByte", "RxFByte"),
    ("CheckFByte", "IbiReadAck"),
    ("TxAckFByte", "RxSByte"),
    ("TxAckFByte", "WaitRestart"),
    ("TxAckFByte", "RxFByte"),
    ("RxSByte", "RxSByteRepeated"),
    ("RxSByte", "CheckSByte"),
    ("RxSByte", "RxFByte"),
    ("RxSByteRepeated", "CheckSByte"),
    ("CheckSByte", "TxAckSByte"),
    ("CheckSByte", "WaitRestart"),
    ("TxAckSByte", "RxPWriteData"),
    ("TxAckSByte", "TxPReadData"),
    ("TxAckSByte", "RxFByte"),
    ("RxPWriteData", "RxPWriteTbit"),
    ("RxPWriteData", "RxFByte"),
    ("RxPWriteData", "Idle"),
    ("RxPWriteTbit", "RxPWriteData"),
    ("RxPWriteTbit", "RxFByte"),
    ("RxPWriteTbit", "Idle"),
    ("TxPReadData", "TxPReadTbitCont"),
    ("TxPReadData", "TxPReadTbitEnd"),
    ("TxPReadData", "RxFByte"),
    ("TxPReadData", "Idle"),
    ("TxPReadTbitCont", "TxPReadData"),
    ("TxPReadTbitCont", "WaitRestart"),
    ("TxPReadTbitCont", "RxFByte"),
    ("TxPReadTbitCont", "Idle"),
    ("TxPReadTbitEnd", "RxFByte"),
    ("TxPReadTbitEnd", "Idle"),
    ("WaitRestart", "RxFByte"),
    ("WaitRestart", "Idle"),
    ("DoCCC", "DoneCCC"),
    ("DoCCC", "RxSByte"),
    ("DoCCC", "Idle"),
    ("DoneCCC", "InHDRMode"),
    ("DoneCCC", "Idle"),
    ("DoRstAction", "Idle"),
    ("InHDRMode", "Idle"),
    ("IbiDriveAddr", "IbiReadAck"),
    ("IbiDriveAddr", "IbiSendData"),
    ("IbiReadAck", "WaitRestart"),
    ("IbiReadAck", "IbiSendData"),
    ("IbiReadAck", "RxFByte"),
    ("IbiSendData", "IbiTbitCont"),
    ("IbiSendData", "IbiTbitEnd"),
    ("IbiTbitCont", "IbiSendData"),
    ("IbiTbitCont", "WaitRestart"),
    ("IbiTbitEnd", "WaitRestart"),
    ("IbiTbitEnd", "RxFByte"),
    ("IbiTbitEnd", "IbiSendData"),
}


def _resolve_state(raw):
    """Convert a raw state field (numeric ID or name) to a state name."""
    try:
        state_id = int(raw)
        return STATE_NAMES.get(state_id, f"UNKNOWN({state_id})")
    except ValueError:
        return raw  # already a name (e.g. from .name() output)


def parse_log(path):
    """Parse fsm_transitions.log, return list of (timestamp_str, old_state, new_state)."""
    transitions = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 3:
                print(f"WARNING: skipping malformed line {lineno}: {line!r}", file=sys.stderr)
                continue
            ts_raw = parts[0]
            old_state = _resolve_state(parts[1])
            new_state = _resolve_state(parts[2])
            transitions.append((ts_raw, old_state, new_state))
    return transitions


def parse_timestamp(ts_raw):
    """Convert raw timestamp string to a numeric value (simulator time units)."""
    # Strip common suffixes
    for suffix in ("fs", "ps", "ns", "us", "ms", "s"):
        if ts_raw.endswith(suffix):
            return float(ts_raw[:-len(suffix)])
    return float(ts_raw)


def print_readable_log(transitions):
    """Print aligned, human-readable transition log."""
    print("=" * 70)
    print("FSM STATE TRANSITION LOG")
    print("=" * 70)
    print(f"{'Timestamp':>14s}  {'Old State':<20s} -> {'New State':<20s}")
    print("-" * 70)
    for ts_raw, old_st, new_st in transitions:
        print(f"{ts_raw:>14s}  {old_st:<20s} -> {new_st:<20s}")
    print(f"\nTotal transitions: {len(transitions)}")


def print_frequency_matrix(transitions):
    """Print transition frequency counts."""
    freq = defaultdict(int)
    for _, old_st, new_st in transitions:
        freq[(old_st, new_st)] += 1

    print("\n" + "=" * 70)
    print("TRANSITION FREQUENCY")
    print("=" * 70)
    for (old_st, new_st), count in sorted(freq.items(), key=lambda x: -x[1]):
        print(f"  {old_st:<20s} -> {new_st:<20s}  : {count:>6d}")
    print(f"\nUnique transitions: {len(freq)}")


def print_time_in_state(transitions):
    """Print time-in-state statistics."""
    if len(transitions) < 2:
        print("\n(Not enough transitions for time-in-state analysis)")
        return

    state_durations = defaultdict(list)
    for i in range(len(transitions) - 1):
        ts_cur = parse_timestamp(transitions[i][0])
        ts_next = parse_timestamp(transitions[i + 1][0])
        new_state = transitions[i][2]
        duration = ts_next - ts_cur
        if duration > 0:
            state_durations[new_state].append(duration)

    print("\n" + "=" * 70)
    print("TIME IN STATE (simulator time units)")
    print("=" * 70)
    print(f"  {'State':<20s} {'Count':>6s} {'Min':>12s} {'Max':>12s} {'Total':>12s}")
    print("  " + "-" * 64)
    for state in sorted(state_durations.keys()):
        durs = state_durations[state]
        print(f"  {state:<20s} {len(durs):>6d} {min(durs):>12.1f} {max(durs):>12.1f} {sum(durs):>12.1f}")


def print_unexpected_transitions(transitions):
    """Flag transitions not in the expected graph."""
    unexpected = []
    for ts_raw, old_st, new_st in transitions:
        if (old_st, new_st) not in EXPECTED_TRANSITIONS:
            unexpected.append((ts_raw, old_st, new_st))

    print("\n" + "=" * 70)
    print("UNEXPECTED TRANSITIONS")
    print("=" * 70)
    if not unexpected:
        print("  None — all transitions match expected FSM graph.")
    else:
        print(f"  Found {len(unexpected)} unexpected transition(s):")
        for ts_raw, old_st, new_st in unexpected:
            print(f"    {ts_raw:>14s}  {old_st:<20s} -> {new_st:<20s}  *** REVIEW ***")


def main():
    parser = argparse.ArgumentParser(
        description="Parse and analyze i3c_target_fsm state transition logs.")
    parser.add_argument("logfile", nargs="?", default="fsm_transitions.log",
                        help="Path to fsm_transitions.log (default: fsm_transitions.log)")
    args = parser.parse_args()

    log_path = Path(args.logfile)
    if not log_path.exists():
        print(f"ERROR: {log_path} not found.", file=sys.stderr)
        sys.exit(1)

    transitions = parse_log(log_path)
    if not transitions:
        print("No transitions found in log file.")
        sys.exit(0)

    print_readable_log(transitions)
    print_frequency_matrix(transitions)
    print_time_in_state(transitions)
    print_unexpected_transitions(transitions)


if __name__ == "__main__":
    main()
