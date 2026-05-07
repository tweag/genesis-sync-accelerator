#!/usr/bin/env python3
"""Plot GSA throughput matrix from sweep-matrix.csv.

Emits four PNGs into the output directory:
  throughput-mbps.png           — MB/s vs batch size, one line per parallel
  throughput-blocks.png         — blocks/s vs batch size, one line per parallel
  throughput-heatmap-mbps.png   — MB/s heatmap (parallel × batch)
  throughput-scaling.png        — MB/s vs parallel clients, one line per batch

Usage:
  python3 plot.py [csv-path] [out-dir]

Defaults to sweep-matrix.csv in CWD and writes plots into CWD.
"""
import csv
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

CSV = Path(sys.argv[1] if len(sys.argv) > 1 else "sweep-matrix.csv")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else ".")
OUT.mkdir(parents=True, exist_ok=True)

rows = []
with CSV.open() as f:
    for r in csv.DictReader(f):
        if not r.get("blocks_per_sec"):
            continue
        rows.append(
            {
                "batch": int(r["batch"]),
                "parallel": int(r["parallel"]),
                "bps": float(r["blocks_per_sec"]),
                "mbps": float(r["mb_per_sec"]),
                "bpb": float(r["bytes_per_block"]) if r.get("bytes_per_block") else 0.0,
            }
        )

batches = sorted({r["batch"] for r in rows})
parallels = sorted({r["parallel"] for r in rows})
print(f"batches={batches}  parallels={parallels}  rows={len(rows)}")


def grid(key):
    m = np.zeros((len(parallels), len(batches)))
    for r in rows:
        i = parallels.index(r["parallel"])
        j = batches.index(r["batch"])
        m[i, j] = r[key]
    return m


mbps = grid("mbps")
bps = grid("bps")

# MB/s vs batch, one line per parallel
plt.figure(figsize=(10, 6))
for i, p in enumerate(parallels):
    plt.plot(batches, mbps[i], marker="o", label=f"parallel={p}")
plt.xscale("log")
plt.xticks(batches, [str(b) for b in batches])
plt.xlabel("Batch size (points per MsgRequestRange)")
plt.ylabel("MB / s")
plt.title("GSA throughput (MB/s) — Byron blocks, warm cache")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()
plt.savefig(OUT / "throughput-mbps.png", dpi=120)
plt.close()

# blocks/s vs batch
plt.figure(figsize=(10, 6))
for i, p in enumerate(parallels):
    plt.plot(batches, bps[i], marker="o", label=f"parallel={p}")
plt.xscale("log")
plt.xticks(batches, [str(b) for b in batches])
plt.xlabel("Batch size")
plt.ylabel("blocks / s")
plt.title("GSA throughput (blocks/s)")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()
plt.savefig(OUT / "throughput-blocks.png", dpi=120)
plt.close()

# MB/s heatmap
fig, ax = plt.subplots(figsize=(9, 5))
im = ax.imshow(mbps, aspect="auto", cmap="viridis")
ax.set_xticks(range(len(batches)), [str(b) for b in batches])
ax.set_yticks(range(len(parallels)), [str(p) for p in parallels])
ax.set_xlabel("Batch size")
ax.set_ylabel("Parallel clients")
ax.set_title("GSA throughput heatmap (MB/s)")
peak = mbps.max() if mbps.size else 1.0
for i in range(mbps.shape[0]):
    for j in range(mbps.shape[1]):
        ax.text(
            j,
            i,
            f"{mbps[i, j]:.1f}",
            ha="center",
            va="center",
            color="white" if mbps[i, j] < peak * 0.55 else "black",
            fontsize=9,
        )
plt.colorbar(im, label="MB/s")
plt.tight_layout()
plt.savefig(OUT / "throughput-heatmap-mbps.png", dpi=120)
plt.close()

# MB/s vs parallel, one line per batch
plt.figure(figsize=(10, 6))
for j, b in enumerate(batches):
    plt.plot(parallels, mbps[:, j], marker="s", label=f"batch={b}")
plt.xlabel("Parallel clients")
plt.ylabel("MB / s")
plt.title("GSA throughput scaling with clients")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()
plt.savefig(OUT / "throughput-scaling.png", dpi=120)
plt.close()

print(f"plots → {OUT}/throughput-*.png")
