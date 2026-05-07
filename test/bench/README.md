# GSA bench harness

Self-contained workflow for driving GSA against a real mainnet ImmutableDB
on the host machine. `gsa-bench` measures synthetic throughput;
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
