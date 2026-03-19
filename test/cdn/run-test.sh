#!/usr/bin/env bash
#
# Integration test for CDN chunk uploading.
#
# Runs a cardano-node syncing preprod, alongside MinIO and chunk-uploader,
# verifying over time that new chunks are detected and pushed to the CDN.
#
# Usage:
#   nix develop .#integration-test
#   bash test/cdn/run-test.sh
#
# Demo mode (tmux UI with live logs):
#   DEMO=1 bash test/cdn/run-test.sh
#
# Environment variables:
#   MIN_CHUNKS        Target uploaded chunks before validation (default: 5)
#   TIMEOUT           Max seconds for sync + upload (default: 600)
#   MINIO_PORT        MinIO S3 API port (default: 9100)
#   NODE_PORT         cardano-node port (default: 3001)
#   POLL_INTERVAL     chunk-uploader poll interval in seconds (default: 2)
#   CHUNK_UPLOADER    Path to chunk-uploader binary (default: found on PATH)
#   KEEP_WORKDIR      Set to 1 to preserve temp dir
#   DEMO              Set to 1 for tmux demo mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config files live in the GSA integration test directory.
CONFIG_DIR="$(cd "$SCRIPT_DIR/../integration/config" && pwd)"

source "$SCRIPT_DIR/lib.sh"

# ── Hook A: Demo bootstrap ──────────────────────────────────────────────────

if demo_is_active; then
  demo_require_tmux
  demo_reexec_in_tmux
fi

# ── Configuration ────────────────────────────────────────────────────────────

MIN_CHUNKS="${MIN_CHUNKS:-5}"
TIMEOUT="${TIMEOUT:-600}"
MINIO_PORT="${MINIO_PORT:-9100}"
MINIO_CONSOLE_PORT=$((MINIO_PORT + 1))
NODE_PORT="${NODE_PORT:-3001}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
CHUNK_UPLOADER="${CHUNK_UPLOADER:-chunk-uploader}"
BUCKET="test-chunks"
S3_PREFIX="immutable/"
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
CONFIG="$CONFIG_DIR/config.json"
POLL_SLEEP=5

# ── Pre-flight checks ───────────────────────────────────────────────────────

for cmd in cardano-node minio mc "$CHUNK_UPLOADER" curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "${RED}Required command not found: $cmd${NC}"
    echo "Run: nix develop .#integration-test"
    exit 1
  fi
done

# ── Cleanup ──────────────────────────────────────────────────────────────────

PIDS=()
TMPDIR=""

cleanup() {
  local exit_code=$?
  echo ""
  echo "=== Cleanup ==="
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "  Stopping pid $pid"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    if [[ "${KEEP_WORKDIR:-}" == "1" ]] || [[ "${KEEP_WORKDIR:-}" != "0" && $exit_code -ne 0 ]]; then
      echo "  Keeping workdir for inspection: $TMPDIR"
    else
      echo "  Removing $TMPDIR"
      rm -rf "$TMPDIR"
    fi
  fi
}
trap cleanup EXIT

# ── Ephemeral workdir ────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t cdn-test.XXXXXX)"
NODE_DB="$TMPDIR/node-db"
MINIO_DATA="$TMPDIR/minio-data"
MC_CONFIG="$TMPDIR/mc-config"
mkdir -p "$NODE_DB" "$MINIO_DATA" "$MC_CONFIG"
echo "  Workdir: $TMPDIR"

# ── Download peer-snapshot ───────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Downloading peer-snapshot ===${NC}"

PEER_SNAPSHOT_URL="https://book.play.dev.cardano.org/environments/preprod/peer-snapshot.json"
PEER_SNAPSHOT="$CONFIG_DIR/peer-snapshot.json"
curl -sSfL "$PEER_SNAPSHOT_URL" -o "$PEER_SNAPSHOT"
echo "  Downloaded peer-snapshot.json"

# ── Start MinIO ──────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting MinIO ===${NC}"

MINIO_PID=$(start_minio "$MINIO_DATA" "$MINIO_PORT" "$MINIO_CONSOLE_PORT" \
            "$MINIO_USER" "$MINIO_PASS" "$TMPDIR/minio.log")
PIDS+=($MINIO_PID)

wait_for_minio "$MINIO_PORT" 15
setup_minio_bucket "$MINIO_PORT" "$MINIO_USER" "$MINIO_PASS" "$BUCKET" "$MC_CONFIG"

# ── Start cardano-node ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting cardano-node (preprod) ===${NC}"

NODE_TOPOLOGY="$CONFIG_DIR/topology.json"

NODE_PID=$(start_cardano_node "$CONFIG" "$NODE_DB" "$NODE_TOPOLOGY" "$NODE_PORT" \
           "$TMPDIR/node.sock" "$TMPDIR/node.log")
PIDS+=($NODE_PID)
echo "  cardano-node started (pid $NODE_PID)"

# ── Wait for immutable/ directory ────────────────────────────────────────────

echo ""
echo "${BOLD}=== Waiting for immutable/ directory ===${NC}"

IMMUTABLE_DIR="$NODE_DB/immutable"
ELAPSED=0
while [[ ! -d "$IMMUTABLE_DIR" ]]; do
  if (( ELAPSED >= 120 )); then
    echo "  ${RED}immutable/ directory did not appear within 120s${NC}"
    echo "--- node log (last 30 lines) ---"
    tail -30 "$TMPDIR/node.log" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    echo "  ${RED}cardano-node died before creating immutable/${NC}"
    echo "--- node log ---"
    cat "$TMPDIR/node.log" 2>/dev/null || true
    exit 1
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo "  immutable/ appeared after ${ELAPSED}s"

# ── Start chunk-uploader ─────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting chunk-uploader ===${NC}"

STATE_FILE="$TMPDIR/uploader-state"

UPLOADER_PID=$(start_chunk_uploader "$IMMUTABLE_DIR" "$BUCKET" "$S3_PREFIX" \
               "http://127.0.0.1:${MINIO_PORT}" "us-east-1" \
               "$POLL_INTERVAL" "$STATE_FILE" "$MINIO_USER" "$MINIO_PASS" \
               "$TMPDIR/uploader.log")
PIDS+=($UPLOADER_PID)
echo "  chunk-uploader started (pid $UPLOADER_PID)"

# ── Hook B: Create demo layout ──────────────────────────────────────────────

if demo_is_active; then
  touch "$TMPDIR/node.log" "$TMPDIR/uploader.log" "$TMPDIR/minio.log"
  demo_create_layout "$TMPDIR/node.log" "$TMPDIR/uploader.log" "$TMPDIR/minio.log"
fi

# ── Monitoring phase: poll until MIN_CHUNKS uploaded ─────────────────────────

echo ""
if demo_is_active; then
  echo "${BOLD}=== Waiting for chunks to sync & upload ===${NC}"
else
  echo "${BOLD}=== Monitoring: waiting for >= $MIN_CHUNKS chunks in MinIO ===${NC}"
fi

ELAPSED=0
EARLY_SNAPSHOT="0"

while (( ELAPSED < TIMEOUT )); do
  LOCAL_CHUNKS=$(count_local_chunks "$IMMUTABLE_DIR" | tr -d '[:space:]')
  MINIO_CHUNKS=$(count_minio_chunks "$BUCKET" "$S3_PREFIX" "$MC_CONFIG" | tr -d '[:space:]')
  MINIO_CHUNKS="${MINIO_CHUNKS:-0}"

  echo "  ${ELAPSED}/${TIMEOUT}s — local: ${LOCAL_CHUNKS} chunks | MinIO: ${MINIO_CHUNKS} chunks"

  if (( MINIO_CHUNKS >= MIN_CHUNKS )); then
    echo "  ${GREEN}>= $MIN_CHUNKS chunks in MinIO${NC}"
    break
  fi

  EARLY_SNAPSHOT="$MINIO_CHUNKS"

  # Check components are still alive.
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    echo "  ${RED}cardano-node died!${NC}"
    echo "--- node log (last 30 lines) ---"
    tail -30 "$TMPDIR/node.log" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$UPLOADER_PID" 2>/dev/null; then
    echo "  ${RED}chunk-uploader died!${NC}"
    echo "--- uploader log ---"
    cat "$TMPDIR/uploader.log" 2>/dev/null || true
    exit 1
  fi

  sleep "$POLL_SLEEP"
  ELAPSED=$((ELAPSED + POLL_SLEEP))
done

if (( ELAPSED >= TIMEOUT )); then
  echo "  ${RED}Timeout after ${TIMEOUT}s (local: $LOCAL_CHUNKS, MinIO: $MINIO_CHUNKS)${NC}"
  echo "--- uploader log (last 30 lines) ---"
  tail -30 "$TMPDIR/uploader.log" 2>/dev/null || true
  echo "--- node log (last 30 lines) ---"
  tail -30 "$TMPDIR/node.log" 2>/dev/null || true
  exit 1
fi

# Record final MinIO count before stopping.
FINAL_MINIO_COUNT=$(count_minio_chunks "$BUCKET" "$S3_PREFIX" "$MC_CONFIG" | tr -d '[:space:]')
FINAL_MINIO_COUNT="${FINAL_MINIO_COUNT:-0}"

# ── Stop node and uploader before validation ─────────────────────────────────

echo ""
echo "${BOLD}=== Stopping node and uploader ===${NC}"

if kill -0 "$NODE_PID" 2>/dev/null; then
  kill "$NODE_PID" 2>/dev/null || true
  wait "$NODE_PID" 2>/dev/null || true
  echo "  cardano-node stopped"
fi

if kill -0 "$UPLOADER_PID" 2>/dev/null; then
  kill "$UPLOADER_PID" 2>/dev/null || true
  wait "$UPLOADER_PID" 2>/dev/null || true
  echo "  chunk-uploader stopped"
fi

# ── Hook C: Demo transition to validation ────────────────────────────────────

demo_is_active && demo_prompt "Uploads complete. Press Enter to run validation..."

# ── Validation ───────────────────────────────────────────────────────────────

if demo_is_active; then
  echo ""
  echo "${BOLD}=== Running validation ===${NC}"
  demo_run_checks_in_panes "$SCRIPT_DIR" "$TMPDIR" "$IMMUTABLE_DIR" "$BUCKET" "$S3_PREFIX" \
    "$MC_CONFIG" "$STATE_FILE" "${EARLY_SNAPSHOT:-0}" "$FINAL_MINIO_COUNT"
  VALIDATION_RC=$?
else
  VALIDATION_RC=0

  # ── Phase 1: Over-time proof ───────────────────────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 1: Over-time upload proof ===${NC}"

  check_uploads_increased "$EARLY_SNAPSHOT" "$FINAL_MINIO_COUNT" || VALIDATION_RC=1

  # ── Phase 2: Upload integrity ──────────────────────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 2: Upload integrity ===${NC}"

  DOWNLOAD_DIR="$TMPDIR/downloaded"
  check_upload_integrity "$IMMUTABLE_DIR" "$BUCKET" "$S3_PREFIX" "$MC_CONFIG" "$DOWNLOAD_DIR" || VALIDATION_RC=1

  # ── Phase 3: Tip exclusion ─────────────────────────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 3: Tip exclusion ===${NC}"

  check_tip_not_uploaded "$IMMUTABLE_DIR" "$BUCKET" "$S3_PREFIX" "$MC_CONFIG" || VALIDATION_RC=1

  # ── Phase 4: State file ────────────────────────────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 4: State file ===${NC}"

  check_state_file "$STATE_FILE" "$BUCKET" "$S3_PREFIX" "$MC_CONFIG" || VALIDATION_RC=1

  # ── Result ─────────────────────────────────────────────────────────────────

  if (( VALIDATION_RC == 0 )); then
    echo ""
    echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
  else
    echo ""
    echo "${RED}${BOLD}=== SOME CHECKS FAILED ===${NC}"
    echo "--- uploader log (last 30 lines) ---"
    tail -30 "$TMPDIR/uploader.log" 2>/dev/null || true
  fi
fi

# ── Hook D: Demo cleanup and exit ────────────────────────────────────────────

if demo_is_active; then
  if (( VALIDATION_RC == 0 )); then
    demo_prompt "All checks passed. Press Enter to exit..."
  else
    demo_prompt "Some checks failed. Press Enter to exit..."
  fi
  tmux kill-session 2>/dev/null || true
fi

exit "${VALIDATION_RC:-0}"
