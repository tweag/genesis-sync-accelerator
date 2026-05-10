#!/usr/bin/env bash
#
# GSA throughput sweep: max-in-flight × batch_size matrix on a single
# connection. This is the cardano-node-shaped concurrency model — pipelined
# requests on one TCP connection, not multiple TCP connections.
#
# Drives `gsa-bench` against an already-running GSA (which must already be
# serving from a populated chunk cache; see `test/bench/run-local.sh`).
#
# Emits sweep-pipeline.csv with one row per (BATCH, K) cell:
#   batch,max_in_flight,duration_s,blocks,bytes,blocks_per_sec,mb_per_sec,bytes_per_block
#
# Usage:
#   nix develop .#integration-test
#   GSA_PORT=8781 NODE_CONFIG=~/gsa-snapshot/config/config.json \
#     bash test/bench/sweep-pipeline.sh
#
# Env (sensible defaults; override as needed):
#   BENCH            Path to gsa-bench (default: cabal-built one in dist-newstyle)
#   GSA_HOST         GSA host (default: 127.0.0.1)
#   GSA_PORT         GSA port (default: 8781)
#   NODE_CONFIG      Cardano network config.json (default: $HOME/gsa-snapshot/config/config.json)
#   OUT              Output CSV path (default: ./sweep-pipeline.csv)
#   DUR              Per-cell duration in seconds (default: 15)
#   BATCHES          Space-separated batch sizes (default: "4 16 64 256 1024")
#   MAX_IN_FLIGHTS   Space-separated pipeline depths (default: "1 4 16 64 100")
#   WARMUP_BATCH     Warm-up batch size (default: 256)
#   WARMUP_K         Warm-up max-in-flight (default: 16)
#   WARMUP_DURATION  Warm-up duration in seconds (default: 10)

set -u

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null \
              || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)")"

BENCH="${BENCH:-$(find "$REPO_ROOT/dist-newstyle" -name gsa-bench -type f -executable 2>/dev/null | head -1)}"
GSA_HOST="${GSA_HOST:-127.0.0.1}"
GSA_PORT="${GSA_PORT:-8781}"
NODE_CONFIG="${NODE_CONFIG:-$HOME/gsa-snapshot/config/config.json}"
OUT="${OUT:-./sweep-pipeline.csv}"
DUR="${DUR:-15}"
BATCHES="${BATCHES:-4 16 64 256 1024}"
MAX_IN_FLIGHTS="${MAX_IN_FLIGHTS:-1 4 16 64 100}"
WARMUP_BATCH="${WARMUP_BATCH:-256}"
WARMUP_K="${WARMUP_K:-16}"
WARMUP_DURATION="${WARMUP_DURATION:-10}"

if [[ -z "$BENCH" || ! -x "$BENCH" ]]; then
  echo "error: gsa-bench not found. Build first: cabal build exe:gsa-bench" >&2
  exit 1
fi
if [[ ! -f "$NODE_CONFIG" ]]; then
  echo "error: NODE_CONFIG not found at $NODE_CONFIG" >&2
  exit 1
fi
if ! ss -ltn 2>/dev/null | grep -q ":$GSA_PORT\b"; then
  echo "error: nothing listening on $GSA_HOST:$GSA_PORT — start GSA first" >&2
  exit 1
fi

# Warm the GSA's chunk cache so cold-start I/O doesn't pollute the first cell.
echo "warmup: parallel=1 max-in-flight=$WARMUP_K batch=$WARMUP_BATCH duration=${WARMUP_DURATION}s"
"$BENCH" --host "$GSA_HOST" --port "$GSA_PORT" --node-config "$NODE_CONFIG" \
  --duration "$WARMUP_DURATION" --parallel 1 \
  --max-in-flight "$WARMUP_K" --batch-size "$WARMUP_BATCH" \
  --report-interval 30 >/dev/null 2>&1
echo "warmup done"

echo "batch,max_in_flight,duration_s,blocks,bytes,blocks_per_sec,mb_per_sec,bytes_per_block" > "$OUT"

for BATCH in $BATCHES; do
  for K in $MAX_IN_FLIGHTS; do
    RESULT=$(timeout $((DUR + 10)) "$BENCH" \
      --host "$GSA_HOST" --port "$GSA_PORT" --node-config "$NODE_CONFIG" \
      --duration "$DUR" --parallel 1 --max-in-flight "$K" --batch-size "$BATCH" \
      --report-interval 30 2>&1 | grep '^{' | head -1)
    if [[ -n "$RESULT" ]]; then
      DUR_S=$(  echo "$RESULT" | sed -n 's/.*"duration_s":\([0-9.]*\).*/\1/p')
      BLOCKS=$( echo "$RESULT" | sed -n 's/.*"blocks":\([0-9]*\).*/\1/p')
      BYTES=$(  echo "$RESULT" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
      BPS=$(    echo "$RESULT" | sed -n 's/.*"blocks_per_sec":\([0-9.]*\).*/\1/p')
      MBPS=$(   echo "$RESULT" | sed -n 's/.*"mb_per_sec":\([0-9.]*\).*/\1/p')
      BPB=$(python3 -c "print(f'{$BYTES/$BLOCKS:.2f}')" 2>/dev/null || echo 0)
      printf "%d,%d,%s,%s,%s,%s,%s,%s\n" \
        "$BATCH" "$K" "$DUR_S" "$BLOCKS" "$BYTES" "$BPS" "$MBPS" "$BPB" \
        | tee -a "$OUT"
    else
      echo "$BATCH,$K,FAILED" | tee -a "$OUT"
    fi
    sleep 1
  done
done

echo "done → $OUT ($(wc -l < "$OUT") lines incl. header)"
