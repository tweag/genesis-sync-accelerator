#!/usr/bin/env python3
"""Per-era cardano-node consumption rate, from the fixed era-bench dataset.

Reads `test/bench/analysis/bandwidth-headroom/era-bench.csv` (columns:
`era, anchor_block, …, real_sync_bps, …`) and emits
`sync-rate-per-era.png`: one bar per era, real-sync blocks/s.

The rate column comes from the prior 8.75 M-block mainnet sync analysis;
this script just plots it.

Usage:
  python3 plot-sync-rate.py [csv-path] [out-dir]
"""
import csv
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

CSV = Path(
    sys.argv[1]
    if len(sys.argv) > 1
    else "test/bench/analysis/bandwidth-headroom/era-bench.csv"
)
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "doc/figures/")
OUT.mkdir(parents=True, exist_ok=True)

# Order eras chronologically; collapse multiple anchor points per era
# (alonzo-65/70/75) into a single bar by taking their mean — they share
# the same real_sync_bps so the average is just that value.
ERA_ORDER = ["byron", "shelley", "allegra", "mary", "alonzo", "babbage"]


def era_key(label: str) -> str | None:
    for e in ERA_ORDER:
        if label.startswith(e):
            return e
    return None


per_era: dict[str, list[float]] = {}
with CSV.open() as f:
    for row in csv.DictReader(f):
        e = era_key(row["era"])
        if e is None:
            continue
        try:
            r = float(row["real_sync_bps"])
        except (KeyError, ValueError):
            continue
        per_era.setdefault(e, []).append(r)

eras = [e for e in ERA_ORDER if e in per_era]
rates = [sum(per_era[e]) / len(per_era[e]) for e in eras]
for e, r in zip(eras, rates):
    print(f"{e:9s}  rate={r:>7.1f} blocks/s")

fig, ax = plt.subplots(figsize=(9, 5))
bars = ax.bar(eras, rates, color="#3a7bd5")
ax.set_ylabel("blocks / s (real-sync)")
ax.set_xlabel("Era")
ax.set_title("cardano-node consumption rate during a full mainnet sync, by era")
ax.grid(True, alpha=0.3, axis="y")
for bar, rate in zip(bars, rates):
    ax.text(
        bar.get_x() + bar.get_width() / 2,
        bar.get_height(),
        f"{rate:.0f}",
        ha="center",
        va="bottom",
        fontsize=10,
    )
plt.tight_layout()
out_png = OUT / "sync-rate-per-era.png"
plt.savefig(out_png, dpi=120)
plt.close()
print(f"→ {out_png}")
