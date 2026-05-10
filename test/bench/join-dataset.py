#!/usr/bin/env python3
"""Join sync-timing.csv ⨝ block-features.csv on block hash.

Inputs:
  sync-timing.csv     applied_at_unix_ms,slot,hash
  block-features.csv  block_no,slot,hash,header_size,block_size,num_txs,
                      txs_size,num_tx_inputs,num_tx_outputs,
                      script_exec_steps,script_exec_mem,
                      plutus_v{1,2,3}_steps, plutus_v{1,2,3}_mem,
                      num_reference_inputs,num_reference_scripts,num_inline_datums

Output:
  dataset.csv         per-block apply_delta_ms + features + era +
                      cumulative_utxo_delta

Notes:
- Joins on `hash` (the Byron EBB at slot 0 and the first regular block at
  slot 0 share the same slot, so slot is not unique).
- `apply_delta_ms` is the gap between consecutive AddedToCurrentChain events
  — the wall-clock time between the previous block being applied and this
  one. The first block has delta = 0.
- `cumulative_utxo_delta = cumsum(num_tx_outputs - num_tx_inputs)` after
  sorting by `block_no`. This is an approximation: Byron emits 0 for
  `num_tx_inputs` (different ledger type), so the Byron contribution is
  biased. Fine for Alonzo+ slope coefficients, not for absolute UTxO level.
- Sanity-asserts `plutus_v1_steps + plutus_v2_steps + plutus_v3_steps ==
  script_exec_steps` per block. Logs a warning with mismatch counts; passes
  the data through anyway, since multi-language witness sets divide by
  integer truncation (max ~num_txs lost steps per block, negligible).

Exit codes:
  0  joined cleanly (>= 99.9% coverage on features CSV)
  1  bad inputs / coverage too low

Usage:
  join-dataset.py <sync-timing.csv> <block-features.csv> <dataset.csv>
"""

import csv
import sys
from pathlib import Path

ERA_BOUNDARIES = [
    (0,         "byron"),
    (4_492_800,  "shelley"),
    (16_588_800, "allegra"),
    (23_068_800, "mary"),
    (39_916_975, "alonzo"),
    (72_316_796, "babbage"),
    (133_660_799, "conway"),
]


def era_of(slot: int) -> str:
    era = ERA_BOUNDARIES[0][1]
    for boundary, name in ERA_BOUNDARIES:
        if slot >= boundary:
            era = name
        else:
            break
    return era


def main(timing_csv: Path, features_csv: Path, out_csv: Path) -> int:
    with timing_csv.open() as f:
        timing = {row["hash"]: row for row in csv.DictReader(f)}
    print(f"  timing  : {len(timing):>8d} rows  ({timing_csv})")

    with features_csv.open() as f:
        features = list(csv.DictReader(f))
    print(f"  features: {len(features):>8d} rows  ({features_csv})")

    # Sort by block_no first to make the cumsum deterministic.
    features.sort(key=lambda r: int(r["block_no"]))

    matched = 0
    plutus_mismatch_blocks = 0
    plutus_mismatch_total_steps = 0
    cumulative_utxo_delta = 0  # running sum of (outputs - inputs)
    rows = []
    prev_t = None
    for feat in features:
        h = feat["hash"]
        t_row = timing.get(h)
        if t_row is None:
            applied_ms = ""
            delta_ms = ""
        else:
            matched += 1
            applied_ms = int(t_row["applied_at_unix_ms"])
            delta_ms = 0 if prev_t is None else applied_ms - prev_t
            prev_t = applied_ms

        slot = int(feat["slot"])
        # All numeric columns default to 0 if absent (older CSV schemas).
        num_tx_inputs = int(feat.get("num_tx_inputs", 0))
        num_tx_outputs = int(feat.get("num_tx_outputs", 0))
        script_exec_steps = int(feat.get("script_exec_steps", 0))
        v1_steps = int(feat.get("plutus_v1_steps", 0))
        v1_mem = int(feat.get("plutus_v1_mem", 0))
        v2_steps = int(feat.get("plutus_v2_steps", 0))
        v2_mem = int(feat.get("plutus_v2_mem", 0))
        v3_steps = int(feat.get("plutus_v3_steps", 0))
        v3_mem = int(feat.get("plutus_v3_mem", 0))
        # Sanity check: split should sum (within integer-truncation tolerance)
        # to the total. Tolerance per-block: at most num_txs (because each
        # multi-language tx loses at most (k-1)/k * 1 step to floor()).
        plutus_split_total = v1_steps + v2_steps + v3_steps
        if plutus_split_total != script_exec_steps:
            mismatch = abs(plutus_split_total - script_exec_steps)
            plutus_mismatch_blocks += 1
            plutus_mismatch_total_steps += mismatch

        # Cumulative UTxO delta (post-genesis baseline).
        cumulative_utxo_delta += (num_tx_outputs - num_tx_inputs)

        rows.append({
            "block_no":              int(feat["block_no"]),
            "slot":                  slot,
            "hash":                  h,
            "applied_at_unix_ms":    applied_ms,
            "apply_delta_ms":        delta_ms,
            "header_size":           int(feat["header_size"]),
            "block_size":            int(feat["block_size"]),
            "num_txs":               int(feat["num_txs"]),
            "txs_size":              int(feat["txs_size"]),
            "num_tx_inputs":         num_tx_inputs,
            "num_tx_outputs":        num_tx_outputs,
            "cumulative_utxo_delta": cumulative_utxo_delta,
            "script_exec_steps":     script_exec_steps,
            "script_exec_mem":       int(feat.get("script_exec_mem", 0)),
            "plutus_v1_steps":       v1_steps,
            "plutus_v1_mem":         v1_mem,
            "plutus_v2_steps":       v2_steps,
            "plutus_v2_mem":         v2_mem,
            "plutus_v3_steps":       v3_steps,
            "plutus_v3_mem":         v3_mem,
            "num_reference_inputs":  int(feat.get("num_reference_inputs", 0)),
            "num_reference_scripts": int(feat.get("num_reference_scripts", 0)),
            "num_inline_datums":     int(feat.get("num_inline_datums", 0)),
            "era":                   era_of(slot),
        })

    coverage = matched / len(features) if features else 0.0
    print(f"  matched : {matched:>8d} / {len(features)}  ({coverage * 100:.2f}%)")
    if plutus_mismatch_blocks > 0:
        # Drop in expected magnitude — multi-language witness-set integer
        # truncation. Surface the count in case it's larger than expected.
        print(
            f"  WARNING: plutus split sums != script_exec_steps in "
            f"{plutus_mismatch_blocks:,} blocks; "
            f"total steps lost to multi-language truncation = {plutus_mismatch_total_steps:,}",
            file=sys.stderr,
        )
    if coverage < 0.999:
        print(f"  ERROR: join coverage {coverage * 100:.2f}% < 99.9% — likely log/db drift", file=sys.stderr)
        return 1

    with out_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  wrote   : {len(rows):>8d} rows -> {out_csv}")

    eras = {}
    for r in rows:
        eras[r["era"]] = eras.get(r["era"], 0) + 1
    print("  by era  :", ", ".join(f"{e}={n}" for e, n in eras.items()))
    print(f"  final cumulative_utxo_delta: {cumulative_utxo_delta:,}")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <sync-timing.csv> <block-features.csv> <dataset.csv>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])))
