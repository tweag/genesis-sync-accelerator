#!/usr/bin/env bash
#
# Phase 1: Baseline Cardano mainnet sync + chunk-uploader.
#
# Starts a cardano-node syncing from the public mainnet network and runs the
# chunk-uploader alongside it, uploading completed ImmutableDB chunks to S3.
#
# This script is idempotent: if services are already running it resumes
# monitoring. If re-run after completion it detects the end-time marker and
# exits immediately.
#
# Usage:
#   nix develop .#integration-test
#   BUCKET=<bucket-name> bash test/benchmark/run-phase1.sh
#
# Environment:
#   BUCKET           (required) S3 bucket name
#   AWS_REGION       Region (default: us-east-1)
#   DATA_DIR         Data root (default: /data)
#   NODE_PORT        cardano-node port (default: 3000)
#   POLL_INTERVAL    Monitoring interval in seconds (default: 60)
#   MAX_SYNC_TIME    Maximum sync time in seconds before giving up (default: 259200 = 72h)
#   USE_SYSTEMD      Set to 1 to manage services via systemd (default: 0, run in foreground)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Configuration ────────────────────────────────────────────────────────────

BUCKET="${BUCKET:?BUCKET env var is required}"
DATA_DIR="${DATA_DIR:-/data}"
CONFIG_DIR="${CONFIG_DIR:-$DATA_DIR/config}"
NODE_PORT="${NODE_PORT:-3000}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_SYNC_TIME="${MAX_SYNC_TIME:-259200}"   # 72 hours
USE_SYSTEMD="${USE_SYSTEMD:-0}"

PHASE_DIR="$DATA_DIR/phase1"
NODE_DB="$PHASE_DIR/node-db"
NODE_LOG="$PHASE_DIR/node.log"
NODE_SOCK="$PHASE_DIR/node.sock"
UPLOADER_LOG="$PHASE_DIR/uploader.log"
UPLOADER_STATE="$PHASE_DIR/state/uploader-state"
START_FILE="$PHASE_DIR/start-time"
END_FILE="$PHASE_DIR/end-time"
PROGRESS_CSV="$PHASE_DIR/progress.csv"

CONFIG="$CONFIG_DIR/config.json"
TOPOLOGY="$CONFIG_DIR/topology.json"

echo "${BOLD}=== Phase 1: Baseline Sync + Chunk Upload ===${NC}"
echo "  Bucket:    $BUCKET"
echo "  Data:      $DATA_DIR"
echo "  Node port: $NODE_PORT"
echo ""

# ── Pre-flight checks ───────────────────────────────────────────────────────

for f in "$CONFIG" "$TOPOLOGY"; do
  if [[ ! -f "$f" ]]; then
    echo "${RED}Missing config file: $f${NC}"
    echo "Run setup-instance.sh first."
    exit 1
  fi
done

if [[ "$USE_SYSTEMD" != "1" ]]; then
  for cmd in cardano-node chunk-uploader aws; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "${RED}Required command not found: $cmd${NC}"
      echo "Enter the dev shell: nix develop .#integration-test"
      exit 1
    fi
  done
fi

# Already completed?
if [[ -f "$END_FILE" ]]; then
  echo "Phase 1 already completed at $(cat "$END_FILE")."
  echo "Remove $END_FILE to re-run."
  exit 0
fi

# ── Cleanup (foreground mode) ────────────────────────────────────────────────

PIDS=()

cleanup() {
  if [[ "$USE_SYSTEMD" == "1" ]]; then
    return
  fi
  echo ""
  echo "=== Cleanup ==="
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "  Stopping pid $pid"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# ── Record start time ────────────────────────────────────────────────────────

mkdir -p "$PHASE_DIR/state" "$NODE_DB"

if [[ ! -f "$START_FILE" ]]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$START_FILE"
  echo "  Start time recorded: $(cat "$START_FILE")"
else
  echo "  Resuming (started at $(cat "$START_FILE"))"
fi

START_EPOCH=$(date -d "$(cat "$START_FILE")" +%s 2>/dev/null \
  || date -u +%s)  # fallback if date format differs

# ── Start cardano-node ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting cardano-node ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  # The template unit uses %i for the phase and port.
  # We need a topology file at /data/phase1/topology.json.
  cp "$TOPOLOGY" "$PHASE_DIR/topology.json"
  svc_start_if_needed "cardano-node@phase1"
else
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    echo "  cardano-node already running (pid $NODE_PID)"
  else
    setsid stdbuf -oL cardano-node run \
      --config "$CONFIG" \
      --database-path "$NODE_DB" \
      --topology "$TOPOLOGY" \
      --port "$NODE_PORT" \
      --socket-path "$NODE_SOCK" \
      >>"$NODE_LOG" 2>&1 &
    NODE_PID=$!
    PIDS+=($NODE_PID)
    echo "  cardano-node started (pid $NODE_PID)"
  fi
fi

# ── Wait for immutable/ directory ────────────────────────────────────────────

echo ""
echo "${BOLD}=== Waiting for immutable/ directory ===${NC}"

IMMUTABLE_DIR="$NODE_DB/immutable"
ELAPSED=0
while [[ ! -d "$IMMUTABLE_DIR" ]]; do
  if (( ELAPSED >= 300 )); then
    echo "  ${RED}immutable/ directory did not appear within 300s${NC}"
    echo "--- node log (last 30 lines) ---"
    tail -30 "$NODE_LOG" 2>/dev/null || true
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "  immutable/ appeared after ${ELAPSED}s"

# ── Start chunk-uploader ─────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting chunk-uploader ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  svc_start_if_needed "chunk-uploader"
else
  if [[ -n "${UPLOADER_PID:-}" ]] && kill -0 "$UPLOADER_PID" 2>/dev/null; then
    echo "  chunk-uploader already running (pid $UPLOADER_PID)"
  else
    setsid stdbuf -oL chunk-uploader \
      --immutable-dir "$IMMUTABLE_DIR" \
      --s3-bucket "$BUCKET" \
      --s3-prefix "immutable/" \
      --s3-region "$REGION" \
      --poll-interval 30 \
      --state-file "$UPLOADER_STATE" \
      --config "$CONFIG" \
      >>"$UPLOADER_LOG" 2>&1 &
    UPLOADER_PID=$!
    PIDS+=($UPLOADER_PID)
    echo "  chunk-uploader started (pid $UPLOADER_PID)"
  fi
fi

# ── Monitoring loop ──────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Monitoring sync progress ===${NC}"

if [[ ! -f "$PROGRESS_CSV" ]]; then
  init_progress_csv "$PROGRESS_CSV"
fi

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_EPOCH ))

  # Collect metrics.
  BLOCKS=$(count_immdb_blocks "$IMMUTABLE_DIR")
  CHUNKS=$(count_immdb_chunks "$IMMUTABLE_DIR")
  TIP_SLOT=$(extract_tip_slot "$NODE_LOG")
  UPLOADED=$(read_uploader_state "$UPLOADER_STATE")
  EXPECTED_SLOT=$(expected_current_slot)

  # Log progress.
  log_progress "$PROGRESS_CSV" "$ELAPSED" "$BLOCKS" "$CHUNKS" "$TIP_SLOT" "$UPLOADED" "phase1"

  # Human-readable status.
  HOURS=$(( ELAPSED / 3600 ))
  MINS=$(( (ELAPSED % 3600) / 60 ))
  SLOT_LAG=$(( EXPECTED_SLOT - TIP_SLOT ))
  echo "  ${HOURS}h${MINS}m — blocks: $BLOCKS | chunks: $CHUNKS | slot: $TIP_SLOT (lag: ${SLOT_LAG}) | uploaded: $UPLOADED"

  # Check sync completion.
  if is_sync_complete "$NODE_LOG"; then
    echo ""
    echo "  ${GREEN}Sync complete!${NC} Tip slot $TIP_SLOT is within range of wall-clock ($EXPECTED_SLOT)"
    break
  fi

  # Check timeout.
  if (( ELAPSED >= MAX_SYNC_TIME )); then
    echo ""
    echo "  ${RED}Timeout after ${MAX_SYNC_TIME}s${NC}"
    echo "--- node log (last 50 lines) ---"
    tail -50 "$NODE_LOG" 2>/dev/null || true
    exit 1
  fi

  # Check processes are alive (foreground mode).
  if [[ "$USE_SYSTEMD" != "1" ]]; then
    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "$NODE_PID" 2>/dev/null; then
      echo "  ${RED}cardano-node died!${NC}"
      echo "--- node log (last 50 lines) ---"
      tail -50 "$NODE_LOG" 2>/dev/null || true
      exit 1
    fi
    if [[ -n "${UPLOADER_PID:-}" ]] && ! kill -0 "$UPLOADER_PID" 2>/dev/null; then
      echo "  ${RED}chunk-uploader died — restarting...${NC}"
      echo "--- uploader log (last 20 lines) ---"
      tail -20 "$UPLOADER_LOG" 2>/dev/null || true
      setsid stdbuf -oL chunk-uploader \
        --immutable-dir "$IMMUTABLE_DIR" \
        --s3-bucket "$BUCKET" \
        --s3-prefix "immutable/" \
        --s3-region "$REGION" \
        --poll-interval 30 \
        --state-file "$UPLOADER_STATE" \
        --config "$CONFIG" \
        >>"$UPLOADER_LOG" 2>&1 &
      UPLOADER_PID=$!
      PIDS+=($UPLOADER_PID)
      echo "  chunk-uploader restarted (pid $UPLOADER_PID)"
    fi
  fi

  sleep "$POLL_INTERVAL"
done

# ── Post-sync: let uploader finish ──────────────────────────────────────────

echo ""
echo "${BOLD}=== Waiting for chunk-uploader to finish ===${NC}"
echo "  Giving the uploader 5 minutes to catch up..."

DRAIN_TIMEOUT=300
DRAIN_ELAPSED=0
LAST_UPLOADED=$(read_uploader_state "$UPLOADER_STATE")

while (( DRAIN_ELAPSED < DRAIN_TIMEOUT )); do
  sleep 30
  DRAIN_ELAPSED=$((DRAIN_ELAPSED + 30))
  CURRENT=$(read_uploader_state "$UPLOADER_STATE")
  echo "  ${DRAIN_ELAPSED}/${DRAIN_TIMEOUT}s — uploaded chunk: $CURRENT"

  # Stabilised if no change in two consecutive checks.
  if [[ "$CURRENT" == "$LAST_UPLOADED" ]] && (( DRAIN_ELAPSED >= 60 )); then
    echo "  Upload state stabilised at chunk $CURRENT"
    break
  fi
  LAST_UPLOADED="$CURRENT"
done

# ── Record end time ──────────────────────────────────────────────────────────

date -u +%Y-%m-%dT%H:%M:%SZ > "$END_FILE"
echo ""
echo "${GREEN}Phase 1 complete.${NC}"
echo "  Start: $(cat "$START_FILE")"
echo "  End:   $(cat "$END_FILE")"

# Final metrics.
FINAL_BLOCKS=$(count_immdb_blocks "$IMMUTABLE_DIR")
FINAL_CHUNKS=$(count_immdb_chunks "$IMMUTABLE_DIR")
FINAL_UPLOADED=$(read_uploader_state "$UPLOADER_STATE")
echo "  Blocks:   $FINAL_BLOCKS"
echo "  Chunks:   $FINAL_CHUNKS"
echo "  Uploaded:  $FINAL_UPLOADED"

# ── Stop services ────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Stopping services ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  svc_stop "chunk-uploader"
  svc_stop "cardano-node@phase1"
else
  # cleanup trap handles foreground processes
  :
fi

echo ""
echo "Next: bash test/benchmark/validate.sh"
