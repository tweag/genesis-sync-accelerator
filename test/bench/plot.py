#!/usr/bin/env python3
"""Plot GSA throughput matrix.

Auto-detects the sweep schema from the CSV header:

* `batch,parallel,…` (sweep-matrix.csv) — multi-connection model. Emits:
    throughput-mbps.png           MB/s vs batch, one line per parallel
    throughput-blocks.png         blocks/s vs batch, one line per parallel
    throughput-heatmap-mbps.png   parallel × batch heatmap
    throughput-scaling.png        MB/s vs parallel, one line per batch

* `batch,max_in_flight,…` (sweep-pipeline.csv) — single-connection
  pipelined model (cardano-node-shaped). Emits:
    throughput-pipeline-mbps.png         MB/s vs batch, one line per K
    throughput-pipeline-blocks.png       blocks/s vs batch, one line per K
    throughput-pipeline-heatmap-mbps.png K × batch heatmap

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

with CSV.open() as f:
    reader = csv.DictReader(f)
    fieldnames = reader.fieldnames or []
    if "max_in_flight" in fieldnames:
        SCHEMA = "pipeline"
        Y_KEY = "max_in_flight"
        Y_LABEL = "Max in-flight (K)"
        Y_LEGEND = "K"
        OUT_PREFIX = "throughput-pipeline"
        TITLE_SUFFIX = "single connection, pipelined, Byron warm"
    elif "parallel" in fieldnames:
        SCHEMA = "parallel"
        Y_KEY = "parallel"
        Y_LABEL = "Parallel clients"
        Y_LEGEND = "parallel"
        OUT_PREFIX = "throughput"
        TITLE_SUFFIX = "Byron blocks, warm cache"
    else:
        raise SystemExit(
            f"unrecognised CSV schema in {CSV}: expected `parallel` or `max_in_flight` column"
        )

    rows = []
    for r in reader:
        if not r.get("blocks_per_sec"):
            continue
        rows.append(
            {
                "batch": int(r["batch"]),
                "y": int(r[Y_KEY]),
                "bps": float(r["blocks_per_sec"]),
                "mbps": float(r["mb_per_sec"]),
                "bpb": float(r["bytes_per_block"]) if r.get("bytes_per_block") else 0.0,
            }
        )

batches = sorted({r["batch"] for r in rows})
ys = sorted({r["y"] for r in rows})
print(f"schema={SCHEMA}  batches={batches}  {Y_KEY}s={ys}  rows={len(rows)}")


def grid(key):
    m = np.zeros((len(ys), len(batches)))
    for r in rows:
        i = ys.index(r["y"])
        j = batches.index(r["batch"])
        m[i, j] = r[key]
    return m


mbps = grid("mbps")
bps = grid("bps")

# MB/s vs batch, one line per Y
plt.figure(figsize=(10, 6))
for i, y in enumerate(ys):
    plt.plot(batches, mbps[i], marker="o", label=f"{Y_LEGEND}={y}")
plt.xscale("log")
plt.xticks(batches, [str(b) for b in batches])
plt.xlabel("Batch size (points per MsgRequestRange)")
plt.ylabel("MB / s")
plt.title(f"GSA throughput (MB/s) — {TITLE_SUFFIX}")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()
plt.savefig(OUT / f"{OUT_PREFIX}-mbps.png", dpi=120)
plt.close()

# blocks/s vs batch
plt.figure(figsize=(10, 6))
for i, y in enumerate(ys):
    plt.plot(batches, bps[i], marker="o", label=f"{Y_LEGEND}={y}")
plt.xscale("log")
plt.xticks(batches, [str(b) for b in batches])
plt.xlabel("Batch size")
plt.ylabel("blocks / s")
plt.title(f"GSA throughput (blocks/s) — {TITLE_SUFFIX}")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()
plt.savefig(OUT / f"{OUT_PREFIX}-blocks.png", dpi=120)
plt.close()

# MB/s heatmap
fig, ax = plt.subplots(figsize=(9, 5))
im = ax.imshow(mbps, aspect="auto", cmap="viridis")
ax.set_xticks(range(len(batches)), [str(b) for b in batches])
ax.set_yticks(range(len(ys)), [str(y) for y in ys])
ax.set_xlabel("Batch size")
ax.set_ylabel(Y_LABEL)
ax.set_title(f"GSA throughput heatmap (MB/s) — {TITLE_SUFFIX}")
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
plt.savefig(OUT / f"{OUT_PREFIX}-heatmap-mbps.png", dpi=120)
plt.close()

if SCHEMA == "parallel":
    # MB/s vs parallel, one line per batch — only meaningful for the parallel sweep
    plt.figure(figsize=(10, 6))
    for j, b in enumerate(batches):
        plt.plot(ys, mbps[:, j], marker="s", label=f"batch={b}")
    plt.xlabel(Y_LABEL)
    plt.ylabel("MB / s")
    plt.title("GSA throughput scaling with clients")
    plt.grid(True, alpha=0.4)
    plt.legend()
    plt.tight_layout()
    plt.savefig(OUT / "throughput-scaling.png", dpi=120)
    plt.close()

print(f"plots → {OUT}/{OUT_PREFIX}-*.png")
