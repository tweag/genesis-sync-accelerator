# gsa-bench throughput sweep

Synthetic node-to-node throughput benchmark for GSA. `gsa-bench` opens N
parallel ChainSync+BlockFetch initiator connections against a running
GSA, pulls blocks as fast as possible, and reports throughput.
`sweep-matrix.sh` drives a (`batch_size` × `parallel-clients`) grid;
`plot.py` renders the resulting CSV.

## Prerequisites

- `nix develop .#integration-test` shell (provides `python3` with
  matplotlib + numpy).
- A running GSA listening on `GSA_PORT` against the data source you want
  to benchmark, e.g.:

  ```bash
  genesis-sync-accelerator \
    --node-config $HOME/gsa-snapshot/config/config.json \
    --rs-src-url http://127.0.0.1:9100/chunks/immutable \
    --cache-dir $HOME/gsa-snapshot/local-run/gsa-cache \
    --port 8781
  ```

## Running

```bash
nix develop .#integration-test
cabal build exe:gsa-bench

GSA_PORT=8781 \
NODE_CONFIG=~/gsa-snapshot/config/config.json \
OUT=./sweep-matrix.csv \
bash test/bench/sweep-matrix.sh

python3 test/bench/plot.py sweep-matrix.csv .
```

Output: `sweep-matrix.csv` plus four PNGs (throughput vs batch in MB/s and
blocks/s, a parallel × batch heatmap, and scaling vs parallel clients).

## Environment variables

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
