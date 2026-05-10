# GSA bench harness

Self-contained workflow for driving GSA against a real mainnet ImmutableDB
on the host machine. `gsa-bench` measures synthetic throughput;
`sync-bench.sh` measures wall-clock sync time against `cardano-node`;
`run-local.sh` boots the full local stack (MinIO, GSA, cardano-node) so
either bench can run end-to-end without manual orchestration.

## Prerequisites

- `nix develop .#integration-test` shell (provides `cardano-node`,
  `chunk-uploader`, `minio`, `mc`, `python3` with matplotlib + numpy).
- ~250 GB free under `${SNAPSHOT_DIR:-$HOME/gsa-snapshot}`.
- A mainnet ImmutableDB snapshot. The harness expects it at
  `$SNAPSHOT_DIR/db/immutable/`. Download from
  <https://csnapshots.io>, verify SHA-256, extract there.
- Cardano network configs auto-fetched into `$SNAPSHOT_DIR/config/`
  (config.json, byron/shelley/alonzo/conway-genesis.json, topology.json,
  optional checkpoints.json + peer-snapshot.json).

## Running

### One-shot end-to-end with `cardano-node`

`run-local.sh` boots everything (MinIO seed, GSA, cardano-node) and
watches the consumer until it has imported `STOP_AFTER_CHUNKS` chunks (or
the node tip slot reaches `STOP_AT_TIP_SLOT`):

```bash
nix develop .#integration-test
cabal build all
bash test/bench/run-local.sh
```

Defaults stop after 5 chunks land in the consumer's ImmutableDB. Override
via `STOP_AFTER_CHUNKS`. The first run pays the chunk-uploader's MinIO
seeding cost; subsequent runs reuse the seeded bucket (`SKIP_SEED=1`).

What "success" looks like:

```
+0050s  node_chunks=5 gsa_cache=8 bf_served=12345 bf_recv=12345 starved=0
=== DONE ===
```

If `bf_served > 0` and `node_chunks` increases steadily, the BlockFetch
path is healthy. The status line above is printed every 5 s by
`run-local.sh` itself.

### Throughput sweep (heatmap)

After `run-local.sh` finishes (or with the GSA still up from any prior
session — pidless reuse is fine, the harness preflight-kills its own
processes only):

```bash
# In one terminal: keep GSA up (it's still listening on :8781 from run-local.sh)
# In another terminal:
nix develop .#integration-test
GSA_PORT=8781 \
NODE_CONFIG=~/gsa-snapshot/config/config.json \
OUT=./sweep-matrix.csv \
bash test/bench/sweep-matrix.sh

python3 test/bench/plot.py sweep-matrix.csv .
```

Output: `sweep-matrix.csv` plus four PNGs (throughput vs batch in MB/s
and blocks/s, a parallel × batch heatmap, and scaling vs parallel
clients).

If you want to re-run GSA explicitly (e.g. after a rebuild) without the
node:

```bash
genesis-sync-accelerator \
  --node-config $HOME/gsa-snapshot/config/config.json \
  --rs-src-url http://127.0.0.1:9100/chunks/immutable \
  --cache-dir $HOME/gsa-snapshot/local-run/gsa-cache \
  --port 8781
```

### Sync-rate characterization (`sync-bench.sh`)

Captures a per-block dataset of wall-clock sync time alongside block
content (era, tx count, block size, …). Output schema:

```
results/<UTC-timestamp>/
  sync-timing.csv     applied_at_unix_ms,slot,hash  (live; one row per CopiedBlockToImmutableDB)
  block-features.csv  block_no, slot, hash, header_size, block_size, num_txs, txs_size,
                      num_tx_inputs, num_tx_outputs, script_exec_steps, script_exec_mem,
                      plutus_v{1,2,3}_steps, plutus_v{1,2,3}_mem,
                      num_reference_inputs, num_reference_scripts, num_inline_datums
  dataset.csv         joined; per-block apply_delta_ms + features + era + cumulative_utxo_delta
  run-meta.json       snapshot tip, GSA + node versions, machine info, elapsed time
  node.log, gsa.log   raw, kept for forensic re-parsing
```

The harness tracks per-block apply timing live by patching the trace
config to emit `ChainDB.CopyToImmutableDBEvent.CopiedBlockToImmutableDB`
at severity Debug with no rate cap. Per-block features are extracted
post-sync by `block-features` (a small ouroboros-consensus walker we
build from `tools/block-features.hs`) — `extract-features.sh` is a thin
wrapper around it.

```bash
nix develop .#integration-test
cabal build all   # builds genesis-sync-accelerator + block-features

# Validation run — small, just to exercise the pipeline.
STOP_AFTER_CHUNKS=10 bash test/bench/sync-bench.sh

# Longer run — covers Byron + Byron→Shelley boundary.
STOP_AFTER_CHUNKS=600 bash test/bench/sync-bench.sh

# Full snapshot sync. Look up the snapshot tip slot first:
#   jq .slot $HOME/gsa-snapshot/config/peer-snapshot.json
STOP_AFTER_CHUNKS=999999 STOP_AT_TIP_SLOT=<tip> STALL_TIMEOUT=86400 \
  bash test/bench/sync-bench.sh
```

Sanity checks on the output:

```bash
RES=$(ls -td test/bench/results/* | head -1)
wc -l $RES/{sync-timing,block-features,dataset}.csv
# row counts of timing and features should be equal ± a handful;
# dataset should match features.

awk -F, 'NR>1 {print $NF}' $RES/dataset.csv | sort | uniq -c
# rows per era — should show byron and shelley if you crossed slot 4_492_800.
```

## Environment variables

### `run-local.sh`

| Var | Default | Description |
|---|---|---|
| `SNAPSHOT_DB` | `$HOME/gsa-snapshot/db/immutable` | Extracted snapshot's `immutable/` dir |
| `WORKDIR` | `$HOME/gsa-snapshot/local-run` | Per-run state (logs, gsa-cache, node-db) |
| `CONFIG_DIR` | `$HOME/gsa-snapshot/config` | Cardano network configs (auto-fetched) |
| `MINIO_DATA` | `$HOME/gsa-snapshot/minio-data` | MinIO backing store |
| `MINIO_PORT` | `9100` | MinIO S3 API port |
| `GSA_PORT` | `8781` | GSA listen port |
| `NODE_PORT` | `8782` | cardano-node port |
| `NETWORK` | `mainnet` | Cardano network |
| `SKIP_SEED` | `0` | `1` to skip MinIO seeding (assumes already seeded) |
| `MAX_CACHED_CHUNKS` | `20` | GSA `--max-cached-chunks` |
| `PREFETCH_AHEAD` | `1` | GSA `--prefetch-ahead` |
| `STOP_AFTER_CHUNKS` | `5` | Halt once node-db/immutable has this many chunks |
| `STOP_AT_TIP_SLOT` | unset | Alternative halt condition: node tip slot ≥ this value |
| `STALL_TIMEOUT` | `1800` | Hard ceiling in seconds for the monitor loop |

### `sync-bench.sh`

Same env as `run-local.sh`, plus:

| Var | Default | Description |
|---|---|---|
| `STOP_AFTER_CHUNKS` | `10` | Higher than `run-local.sh`'s default; bump to ~600 to cross Byron→Shelley, or unset and use `STOP_AT_TIP_SLOT` |
| `STALL_TIMEOUT` | `7200` | Hard ceiling for the monitor loop, suitable for a longer run |
| `RESULTS_ROOT` | `./results/` | Per-run subdirs are created under here |
| `FRESH_WORKDIR` | `1` | `0` to **resume** from the previous run's node-db. The orchestrator seeds the new `sync-timing.csv` with the most recent prior one and asks `parse-timing.awk` to append, so the joined `dataset.csv` covers the full timeline (initial run + extension) |

### `sweep-matrix.sh`

| Var | Default | Description |
|---|---|---|
| `BENCH` | autodetected in `dist-newstyle/` | Path to `gsa-bench` |
| `GSA_HOST` | `127.0.0.1` | GSA host |
| `GSA_PORT` | `8781` | GSA port |
| `NODE_CONFIG` | `$HOME/gsa-snapshot/config/config.json` | Cardano `config.json` |
| `OUT` | `./sweep-matrix.csv` | Output CSV |
| `DUR` | `15` | Per-cell duration (s) |
| `BATCHES` | `50 100 250 500 1000 2000 5000` | Batch sizes to sweep |
| `PARALLELS` | `1 2 4 8 16` | Parallel-client counts to sweep |

## Troubleshooting

- **Sweep stops early or shows `FAILED`.** Verify GSA is up
  (`ss -ltn | grep 8781`) and that `gsa-bench` was rebuilt against the
  current source (`cabal build exe:gsa-bench`).
- **`run-local.sh` says "uploader died".** Check `$WORKDIR/uploader.log`.
  Most often the snapshot dir or MinIO endpoint URL is wrong.
- **`PeerStarvedUs` climbing every iteration.** GSA isn't responding to
  BlockFetch (different from "responding slowly"). Tail
  `$WORKDIR/gsa.log` for tracer output (HTTP failures, MinIO 403, etc.).
