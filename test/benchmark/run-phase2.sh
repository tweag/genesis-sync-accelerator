#!/usr/bin/env bash
#
# Phase 2: GSA-accelerated Cardano mainnet sync.
#
# Starts the Genesis Sync Accelerator reading from S3 (populated by Phase 1),
# then syncs a fresh cardano-node through the GSA. Measures total sync time.
#
# Prerequisites:
#   - Phase 1 completed (S3 bucket populated with chunks + tip.json)
#   - setup-instance.sh has been run
#
# Usage:
#   nix develop .#integration-test
#   BUCKET=<bucket-name> bash test/benchmark/run-phase2.sh
#
# Environment:
#   BUCKET             (required) S3 bucket name
#   AWS_REGION         Region (default: us-east-1)
#   DATA_DIR           Data root (default: /data)
#   GSA_PORT           GSA port (default: 3001)
#   NODE_PORT          cardano-node port (default: 3002)
#   MAX_CACHED_CHUNKS  GSA cache size (default: 20)
#   PREFETCH_AHEAD     GSA prefetch window (default: 10)
#   POLL_INTERVAL      Monitoring interval in seconds (default: 60)
#   MAX_SYNC_TIME      Maximum sync time in seconds (default: 259200 = 72h)
#   USE_SYSTEMD        Set to 1 for systemd mode (default: 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Configuration ────────────────────────────────────────────────────────────

BUCKET="${BUCKET:?BUCKET env var is required}"
DATA_DIR="${DATA_DIR:-/data}"
CONFIG_DIR="${CONFIG_DIR:-$DATA_DIR/config}"
GSA_PORT="${GSA_PORT:-3001}"
NODE_PORT="${NODE_PORT:-3002}"
MAX_CACHED_CHUNKS="${MAX_CACHED_CHUNKS:-20}"
PREFETCH_AHEAD="${PREFETCH_AHEAD:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_SYNC_TIME="${MAX_SYNC_TIME:-259200}"
USE_SYSTEMD="${USE_SYSTEMD:-0}"

PHASE_DIR="$DATA_DIR/phase2"
NODE_DB="$PHASE_DIR/node-db"
NODE_LOG="$PHASE_DIR/node.log"
NODE_SOCK="$PHASE_DIR/node.sock"
GSA_LOG="$PHASE_DIR/gsa.log"
GSA_CACHE="$PHASE_DIR/gsa-cache"
START_FILE="$PHASE_DIR/start-time"
END_FILE="$PHASE_DIR/end-time"
PROGRESS_CSV="$PHASE_DIR/progress.csv"

CONFIG="$CONFIG_DIR/config.json"
GSA_TOPOLOGY="$PHASE_DIR/gsa-topology.json"

RS_SRC_URL="https://${BUCKET}.s3.${REGION}.amazonaws.com/immutable"

echo "${BOLD}=== Phase 2: GSA-Accelerated Sync ===${NC}"
echo "  Bucket:    $BUCKET"
echo "  CDN URL:   $RS_SRC_URL"
echo "  GSA port:  $GSA_PORT"
echo "  Node port: $NODE_PORT"
echo ""

# ── Pre-flight checks ───────────────────────────────────────────────────────

if [[ ! -f "$CONFIG" ]]; then
  echo "${RED}Missing config: $CONFIG${NC}"
  echo "Run setup-instance.sh first."
  exit 1
fi

if [[ "$USE_SYSTEMD" != "1" ]]; then
  for cmd in genesis-sync-accelerator cardano-node aws; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "${RED}Required command not found: $cmd${NC}"
      echo "Enter the dev shell: nix develop .#integration-test"
      exit 1
    fi
  done
fi

# Verify S3 has data.
echo "${BOLD}=== Verifying S3 readiness ===${NC}"

if ! s3_object_exists "$BUCKET" "immutable/tip.json" "$REGION"; then
  echo "  ${RED}tip.json not found in S3.${NC} Run Phase 1 first."
  exit 1
fi

S3_CHUNKS=$(s3_count_chunks "$BUCKET" "immutable/" "$REGION")
[[ "$S3_CHUNKS" == "None" || -z "$S3_CHUNKS" ]] && S3_CHUNKS=0
echo "  S3 has $S3_CHUNKS chunks and tip.json"

if (( S3_CHUNKS < 10 )); then
  echo "  ${RED}Too few chunks in S3 ($S3_CHUNKS). Phase 1 may not have completed.${NC}"
  exit 1
fi

# Already completed?
if [[ -f "$END_FILE" ]]; then
  echo "Phase 2 already completed at $(cat "$END_FILE")."
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

# ── Prepare directories ─────────────────────────────────────────────────────

mkdir -p "$NODE_DB" "$GSA_CACHE"

# ── Generate GSA topology ───────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Generating topology ===${NC}"

cat > "$GSA_TOPOLOGY" <<EOF
{
  "localRoots": [
    {
      "accessPoints": [
        {"address": "127.0.0.1", "port": $GSA_PORT}
      ],
      "advertise": false,
      "trustable": true,
      "hotValency": 1
    }
  ],
  "bootstrapPeers": null,
  "peerSnapshotFile": "$CONFIG_DIR/peer-snapshot.json",
  "publicRoots": []
}
EOF

echo "  Written $GSA_TOPOLOGY"
echo "  Node will get block data from GSA at 127.0.0.1:$GSA_PORT"
echo "  Genesis header validation via peer-snapshot peers"

# ── Start GSA ────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting Genesis Sync Accelerator ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  svc_start_if_needed "gsa"
else
  if [[ -n "${GSA_PID:-}" ]] && kill -0 "$GSA_PID" 2>/dev/null; then
    echo "  GSA already running (pid $GSA_PID)"
  else
    setsid stdbuf -oL genesis-sync-accelerator \
      --config "$CONFIG" \
      --rs-src-url "$RS_SRC_URL" \
      --cache-dir "$GSA_CACHE" \
      --max-cached-chunks "$MAX_CACHED_CHUNKS" \
      --prefetch-ahead "$PREFETCH_AHEAD" \
      --port "$GSA_PORT" \
      --addr 127.0.0.1 \
      --tip-refresh-interval 600 \
      >>"$GSA_LOG" 2>&1 &
    GSA_PID=$!
    PIDS+=($GSA_PID)
    echo "  GSA started (pid $GSA_PID)"
  fi
fi

wait_for_port "$GSA_PORT" 30 "GSA"

# ── Record start time ────────────────────────────────────────────────────────

if [[ ! -f "$START_FILE" ]]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$START_FILE"
  echo "  Start time recorded: $(cat "$START_FILE")"
else
  echo "  Resuming (started at $(cat "$START_FILE"))"
fi

START_EPOCH=$(date -d "$(cat "$START_FILE")" +%s 2>/dev/null \
  || date -u +%s)

# ── Start cardano-node ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting cardano-node (GSA consumer) ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  svc_start_if_needed "cardano-node@phase2"
else
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    echo "  cardano-node already running (pid $NODE_PID)"
  else
    setsid stdbuf -oL cardano-node run \
      --config "$CONFIG" \
      --database-path "$NODE_DB" \
      --topology "$GSA_TOPOLOGY" \
      --port "$NODE_PORT" \
      --socket-path "$NODE_SOCK" \
      >>"$NODE_LOG" 2>&1 &
    NODE_PID=$!
    PIDS+=($NODE_PID)
    echo "  cardano-node started (pid $NODE_PID)"
  fi
fi

# ── Monitoring loop ──────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Monitoring sync progress ===${NC}"

IMMUTABLE_DIR="$NODE_DB/immutable"

if [[ ! -f "$PROGRESS_CSV" ]]; then
  init_progress_csv "$PROGRESS_CSV"
fi

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_EPOCH ))

  # Collect metrics.
  BLOCKS=0
  CHUNKS=0
  if [[ -d "$IMMUTABLE_DIR" ]]; then
    BLOCKS=$(count_immdb_blocks "$IMMUTABLE_DIR")
    CHUNKS=$(count_immdb_chunks "$IMMUTABLE_DIR")
  fi
  TIP_SLOT=$(extract_tip_slot "$NODE_LOG")
  EXPECTED_SLOT=$(expected_current_slot)
  CACHE_CHUNKS=$(find "$GSA_CACHE" -name '*.chunk' 2>/dev/null | wc -l)

  # Log progress.
  log_progress "$PROGRESS_CSV" "$ELAPSED" "$BLOCKS" "$CHUNKS" "$TIP_SLOT" "n/a" "phase2"

  # Human-readable status.
  HOURS=$(( ELAPSED / 3600 ))
  MINS=$(( (ELAPSED % 3600) / 60 ))
  SLOT_LAG=$(( EXPECTED_SLOT - TIP_SLOT ))
  echo "  ${HOURS}h${MINS}m — blocks: $BLOCKS | chunks: $CHUNKS | slot: $TIP_SLOT (lag: ${SLOT_LAG}) | gsa-cache: $CACHE_CHUNKS"

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
    echo "--- GSA log (last 50 lines) ---"
    tail -50 "$GSA_LOG" 2>/dev/null || true
    exit 1
  fi

  # Check processes (foreground mode).
  if [[ "$USE_SYSTEMD" != "1" ]]; then
    if [[ -n "${GSA_PID:-}" ]] && ! kill -0 "$GSA_PID" 2>/dev/null; then
      echo "  ${RED}GSA died — restarting...${NC}"
      tail -20 "$GSA_LOG" 2>/dev/null || true
      setsid stdbuf -oL genesis-sync-accelerator \
        --config "$CONFIG" \
        --rs-src-url "$RS_SRC_URL" \
        --cache-dir "$GSA_CACHE" \
        --max-cached-chunks "$MAX_CACHED_CHUNKS" \
        --prefetch-ahead "$PREFETCH_AHEAD" \
        --port "$GSA_PORT" \
        --addr 127.0.0.1 \
        --tip-refresh-interval 600 \
        >>"$GSA_LOG" 2>&1 &
      GSA_PID=$!
      PIDS+=($GSA_PID)
      echo "  GSA restarted (pid $GSA_PID)"
      wait_for_port "$GSA_PORT" 30 "GSA"
    fi
    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "$NODE_PID" 2>/dev/null; then
      echo "  ${RED}cardano-node died!${NC}"
      echo "--- node log (last 50 lines) ---"
      tail -50 "$NODE_LOG" 2>/dev/null || true
      exit 1
    fi
  fi

  sleep "$POLL_INTERVAL"
done

# ── Record end time ──────────────────────────────────────────────────────────

date -u +%Y-%m-%dT%H:%M:%SZ > "$END_FILE"
echo ""
echo "${GREEN}Phase 2 complete.${NC}"
echo "  Start: $(cat "$START_FILE")"
echo "  End:   $(cat "$END_FILE")"

FINAL_BLOCKS=$(count_immdb_blocks "$IMMUTABLE_DIR")
FINAL_CHUNKS=$(count_immdb_chunks "$IMMUTABLE_DIR")
echo "  Blocks: $FINAL_BLOCKS"
echo "  Chunks: $FINAL_CHUNKS"

# ── Stop services ────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Stopping services ===${NC}"

if [[ "$USE_SYSTEMD" == "1" ]]; then
  svc_stop "cardano-node@phase2"
  svc_stop "gsa"
fi

echo ""
echo "Next: bash test/benchmark/report.sh"
