#!/usr/bin/env bash
#
# Sync-rate characterization harness.
#
# Wraps run-local.sh:
#   1. tail -F node.log | gawk parse-timing.awk     -> sync-timing.csv (live)
#   2. run-local.sh sync until STOP_AFTER_CHUNKS or STOP_AT_TIP_SLOT
#   3. extract-features.sh on the resulting node-db -> block-features.csv
#   4. join-dataset.py                              -> dataset.csv
#   5. write run-meta.json
#
# Outputs land in $RESULTS_DIR (default: results/<UTC-timestamp>/).
#
# Usage:
#   nix develop .#integration-test
#   bash test/bench/sync-bench.sh
#
# Environment (most are forwarded to run-local.sh; see its header for full list):
#   STOP_AFTER_CHUNKS  Halt at this many node-side chunks (default: 10 — small
#                      validation run; bump to ~600 to cross Byron→Shelley)
#   STOP_AT_TIP_SLOT   Alternative: halt when node tip slot >= this value
#   STALL_TIMEOUT      Hard ceiling in seconds (default: 7200 — 2h, suitable for
#                      a Byron+early-Shelley prototype on local hardware)
#   RESULTS_ROOT       Where per-run dirs are created (default: ./results next
#                      to this script)
#   FRESH_WORKDIR      1 to wipe $WORKDIR before running (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults tailored for sync-bench (different from run-local.sh's tiny defaults).
export STOP_AFTER_CHUNKS="${STOP_AFTER_CHUNKS:-10}"
export STALL_TIMEOUT="${STALL_TIMEOUT:-7200}"
RESULTS_ROOT="${RESULTS_ROOT:-$SCRIPT_DIR/results}"
FRESH_WORKDIR="${FRESH_WORKDIR:-1}"

# Paths that run-local.sh uses (must agree with its defaults / overrides).
WORKDIR="${WORKDIR:-$HOME/gsa-snapshot/local-run}"
NODE_LOG="$WORKDIR/node.log"
NODE_DB="$WORKDIR/node-db"
CONFIG_DIR="${CONFIG_DIR:-$HOME/gsa-snapshot/config}"
CONFIG_JSON="$CONFIG_DIR/config.json"

export WORKDIR CONFIG_DIR

# ── Preflight ────────────────────────────────────────────────────────────────

for cmd in genesis-sync-accelerator cardano-node db-analyser gawk python3 jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd"
    echo "Enter the dev shell first: nix develop .#integration-test"
    exit 1
  fi
done

# ── Patch trace config: enable per-block events, drop rate limits ────────────
#
# cardano-node's default trace config silences per-block events with a 2/s
# rate cap (see TraceOptions in config.json). For sync-rate characterization
# we need every block, so we promote `CopiedBlockToImmutableDB` to severity
# Debug and remove the maxFrequency caps. Idempotent.

if [[ -f "$CONFIG_JSON" ]]; then
  echo "==> patching $CONFIG_JSON for per-block tracing"
  TMP_CFG=$(mktemp)
  jq '
    .TraceOptions["ChainDB.CopyToImmutableDBEvent.CopiedBlockToImmutableDB"] = {"severity":"Debug"}
    | del(.TraceOptions["BlockFetch.Client.CompletedBlockFetch"].maxFrequency)
    | del(.TraceOptions["ChainDB.AddBlockEvent.AddBlockValidation.ValidCandidate"].maxFrequency)
    | del(.TraceOptions["ChainDB.AddBlockEvent.AddedBlockToQueue"].maxFrequency)
    | del(.TraceOptions["ChainDB.AddBlockEvent.AddedBlockToVolatileDB"].maxFrequency)
    | del(.TraceOptions["ChainDB.CopyToImmutableDBEvent.CopiedBlockToImmutableDB"].maxFrequency)
  ' "$CONFIG_JSON" > "$TMP_CFG" && mv "$TMP_CFG" "$CONFIG_JSON"
fi

# ── Per-run results dir ──────────────────────────────────────────────────────

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$RESULTS_ROOT/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"
echo "==> results dir: $RESULTS_DIR"

TIMING_CSV="$RESULTS_DIR/sync-timing.csv"
FEATURES_CSV="$RESULTS_DIR/block-features.csv"
DATASET_CSV="$RESULTS_DIR/dataset.csv"
META_JSON="$RESULTS_DIR/run-meta.json"

# ── Wipe workdir if requested ────────────────────────────────────────────────

RESUME=0
if [[ "$FRESH_WORKDIR" == "1" ]]; then
  if [[ -d "$WORKDIR/node-db" || -f "$NODE_LOG" || -f "$WORKDIR/gsa.log" ]]; then
    echo "==> wiping $WORKDIR (FRESH_WORKDIR=1)"
    rm -rf "$WORKDIR/node-db" "$WORKDIR/gsa-cache" "$NODE_LOG" "$WORKDIR/gsa.log" \
           "$WORKDIR/node.sock" 2>/dev/null || true
  fi
  # If MinIO is already seeded, skip re-seeding it.
  export SKIP_SEED="${SKIP_SEED:-1}"
else
  # FRESH_WORKDIR=0 → resume mode. Find the most recent previous results dir
  # whose sync-timing.csv has at least one data row, and seed our new
  # sync-timing.csv with it so the eventual join covers the full timeline.
  PREV_TIMING=""
  while IFS= read -r f; do
    [[ -s "$f" ]] && (( $(wc -l < "$f") > 1 )) && { PREV_TIMING="$f"; break; }
  done < <(ls -t "$RESULTS_ROOT"/*/sync-timing.csv 2>/dev/null)
  if [[ -n "$PREV_TIMING" ]]; then
    RESUME=1
    echo "==> resume: seeding sync-timing.csv from $PREV_TIMING ($(($(wc -l < "$PREV_TIMING") - 1)) rows)"
  else
    echo "==> FRESH_WORKDIR=0 but no prior sync-timing.csv found — proceeding as a fresh run"
  fi
  export SKIP_SEED="${SKIP_SEED:-1}"
fi

# ── Spawn live timing parser ─────────────────────────────────────────────────
#
# tail -F retries until the file appears, so we can start it before
# run-local.sh creates the log. gawk reads the stream and writes one row
# per AddedToCurrentChain event with millisecond precision.

mkdir -p "$(dirname "$NODE_LOG")"
: > "$NODE_LOG"  # truncate so we don't pick up events from a previous run

if (( RESUME )); then
  cp "$PREV_TIMING" "$TIMING_CSV"
  AWK_FLAGS="-v skip_header=1"
  REDIR=">>"
else
  AWK_FLAGS=""
  REDIR=">"
fi

echo "==> live timing parser: tail -F $NODE_LOG | parse-timing.awk -> $(basename "$TIMING_CSV") (resume=$RESUME)"
# `setsid` puts the subshell into its own process group, so we can kill the
# whole pipeline (tail + gawk + the subshell itself) via `kill -- -PGID`. A
# plain `kill $PID` on a backgrounded subshell leaves orphaned tail/gawk
# children behind.
setsid bash -c "tail -n +1 -F '$NODE_LOG' 2>/dev/null \
  | gawk $AWK_FLAGS -f '$SCRIPT_DIR/parse-timing.awk' $REDIR '$TIMING_CSV'" &
TAIL_PID=$!

cleanup_tail() {
  if kill -0 "$TAIL_PID" 2>/dev/null; then
    # Negate PID to target the whole process group.
    kill -- -"$TAIL_PID" 2>/dev/null || kill "$TAIL_PID" 2>/dev/null || true
    # gawk may still be flushing buffered output; give it a beat.
    sleep 0.5
  fi
}
trap cleanup_tail EXIT

# ── Run sync ─────────────────────────────────────────────────────────────────

START_UNIX="$(date -u +%s)"
echo "==> starting sync (STOP_AFTER_CHUNKS=$STOP_AFTER_CHUNKS, STOP_AT_TIP_SLOT=${STOP_AT_TIP_SLOT:-<unset>})"

RUN_OK=0
if bash "$SCRIPT_DIR/run-local.sh"; then
  RUN_OK=1
fi
END_UNIX="$(date -u +%s)"

# Drain the tail+gawk pipeline so the CSV is final before we proceed.
sleep 2
cleanup_tail
trap - EXIT

if (( RUN_OK == 0 )); then
  echo "==> sync failed; partial artifacts kept in $RESULTS_DIR" >&2
  exit 1
fi

TIMING_ROWS=$(($(wc -l < "$TIMING_CSV") - 1))
echo "==> sync done (elapsed=$((END_UNIX - START_UNIX))s), captured $TIMING_ROWS timing rows"

# ── Extract features from the synced ImmutableDB ─────────────────────────────

echo "==> extract-features.sh on $NODE_DB"
bash "$SCRIPT_DIR/extract-features.sh" "$NODE_DB" "$CONFIG_JSON" "$FEATURES_CSV"

# ── Join into final dataset ──────────────────────────────────────────────────

echo "==> join-dataset.py"
python3 "$SCRIPT_DIR/join-dataset.py" "$TIMING_CSV" "$FEATURES_CSV" "$DATASET_CSV"

# ── run-meta.json ────────────────────────────────────────────────────────────

GSA_REV="$(cd "$SCRIPT_DIR/../.." && git rev-parse HEAD 2>/dev/null || echo unknown)"
GSA_DIRTY="$(cd "$SCRIPT_DIR/../.." && [[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo true || echo false)"
NODE_VERSION="$(cardano-node --version 2>/dev/null | head -1 || echo unknown)"
GSA_VERSION="$(genesis-sync-accelerator --version 2>/dev/null | head -1 || echo unknown)"
SNAPSHOT_TIP_SLOT="$(jq -r '.slot // empty' < "$CONFIG_DIR/peer-snapshot.json" 2>/dev/null || echo "")"
CPU_MODEL="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/^model name[[:space:]]*:[[:space:]]*//' || echo unknown)"
CPU_COUNT="$(nproc 2>/dev/null || echo unknown)"
MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo unknown)"

cat > "$META_JSON" <<EOF
{
  "timestamp_utc":     "$TIMESTAMP",
  "elapsed_seconds":   $((END_UNIX - START_UNIX)),
  "start_unix":        $START_UNIX,
  "end_unix":          $END_UNIX,
  "stop_after_chunks": $STOP_AFTER_CHUNKS,
  "stop_at_tip_slot":  ${STOP_AT_TIP_SLOT:-null},
  "snapshot_db":       "${SNAPSHOT_DB:-$HOME/gsa-snapshot/db/immutable}",
  "snapshot_tip_slot": ${SNAPSHOT_TIP_SLOT:-null},
  "workdir":           "$WORKDIR",
  "gsa_git_rev":       "$GSA_REV",
  "gsa_git_dirty":     $GSA_DIRTY,
  "gsa_version":       "$GSA_VERSION",
  "node_version":      "$NODE_VERSION",
  "max_cached_chunks": ${MAX_CACHED_CHUNKS:-20},
  "prefetch_ahead":    ${PREFETCH_AHEAD:-1},
  "machine": {
    "cpu_model":  "$CPU_MODEL",
    "cpu_count":  $CPU_COUNT,
    "mem_kb":     ${MEM_KB:-null}
  },
  "timing_rows": $TIMING_ROWS,
  "log_files": {
    "node":      "$NODE_LOG",
    "gsa":       "$WORKDIR/gsa.log"
  }
}
EOF

# ── Copy raw logs alongside the dataset for forensic re-parsing ──────────────

cp -a "$NODE_LOG"        "$RESULTS_DIR/node.log" 2>/dev/null || true
cp -a "$WORKDIR/gsa.log" "$RESULTS_DIR/gsa.log"  2>/dev/null || true

echo ""
echo "==> done"
echo "    $RESULTS_DIR/"
ls -la "$RESULTS_DIR/" | sed 's/^/    /'
