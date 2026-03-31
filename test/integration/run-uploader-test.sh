#!/usr/bin/env bash
#
# Integration test for chunk-uploader.
#
# Starts a local MinIO S3-compatible server, runs chunk-uploader against it,
# and verifies:
#
#   Phase 1: basic uploads: completed chunk triplets are uploaded to MinIO,
#             the tip (highest-numbered) chunk is excluded, and the state file
#             records the last uploaded chunk number.
#
#   Phase 2: resumption: restarting the uploader after adding new chunks
#             uploads only the new ones; the tip exclusion still holds; and
#             previously uploaded objects are untouched.
#
#   Phase 3: tip.json generation: when --config is provided, tip.json is
#             uploaded after a batch of chunks, reflecting the DB tip.
#
# Usage:
#   nix develop .#integration-test
#   bash test/integration/run-uploader-test.sh
#
# Configuration via environment variables:
#   MINIO_PORT       (default: 9000)  Port for the local MinIO server
#   CHUNK_UPLOADER   (default: chunk-uploader)  Path to the binary
#   DB_DIR           (default: ./test-data/source-db)  Source ImmutableDB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

# ── Configuration ─────────────────────────────────────────────────────────────

MINIO_PORT="${MINIO_PORT:-9000}"
CHUNK_UPLOADER="${CHUNK_UPLOADER:-chunk-uploader}"
SOURCE_DB="${DB_DIR:-$SCRIPT_DIR/test-data/source-db}"
IMMUTABLE_SRC="$SOURCE_DB/immutable"
BUCKET_NAME="test-bucket"
S3_PREFIX="immutable/"

# ── Cleanup ───────────────────────────────────────────────────────────────────

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

# ── Ensure source data ────────────────────────────────────────────────────────

echo "${BOLD}=== Checking source data ===${NC}"

MIN_CHUNKS=8
MIN_CHUNKS="$MIN_CHUNKS" DB_DIR="$SOURCE_DB" bash "$SCRIPT_DIR/chain-init.sh"

AVAILABLE=$(find "$IMMUTABLE_SRC" -name '*.chunk' | wc -l)
echo "  Source has $AVAILABLE chunk(s) (need $MIN_CHUNKS)"

# ── Ephemeral workdir ─────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t uploader-test.XXXXXX)"
IMMUTABLE_DIR="$TMPDIR/immutable"
MINIO_DATA="$TMPDIR/minio-data"
STATE_FILE="$TMPDIR/uploader-state"
mkdir -p "$IMMUTABLE_DIR" "$MINIO_DATA"
echo "  Workdir: $TMPDIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Zero-pad a chunk number to 5 digits.
chunk_base() { printf "%05d" "$1"; }

# Copy a chunk triplet from the source ImmutableDB into a target directory.
copy_chunk() {
  local n="$1" dest="$2"
  local base; base=$(chunk_base "$n")
  for ext in chunk primary secondary; do
    cp "$IMMUTABLE_SRC/${base}.${ext}" "$dest/${base}.${ext}"
  done
}

# start_uploader <log_file> [config_path]: start the uploader in the background.
start_uploader() {
  local log_file="$1"
  local config_path="${2:-}"
  local args=(
    --immutable-dir "$IMMUTABLE_DIR"
    --s3-bucket "$BUCKET_NAME"
    --s3-prefix "$S3_PREFIX"
    --s3-endpoint "http://127.0.0.1:$MINIO_PORT"
    --s3-region us-east-1
    --poll-interval 1
    --state-file "$STATE_FILE"
  )
  if [[ -n "$config_path" ]]; then
    args+=(--config "$config_path")
  fi

  AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \
  stdbuf -oL "$CHUNK_UPLOADER" "${args[@]}" >"$log_file" 2>&1 &
  echo $!
}

# wait_for_state <expected> <uploader_pid>: poll the state file until it
# holds <expected>, checking that the uploader is still alive each second.
wait_for_state() {
  local expected="$1" uploader_pid="$2" timeout=30
  local elapsed=0
  while (( elapsed < timeout )); do
    if [[ -f "$STATE_FILE" ]]; then
      local current
      current=$(tr -d '[:space:]' < "$STATE_FILE")
      if [[ "$current" == "$expected" ]]; then
        echo "  State file reached $expected"
        return 0
      fi
    fi
    if ! kill -0 "$uploader_pid" 2>/dev/null; then
      echo "  ${RED}chunk-uploader (pid $uploader_pid) died unexpectedly${NC}"
      echo "--- uploader log ---"
      cat "$TMPDIR/uploader.log" 2>/dev/null || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  local got; got=$(cat "$STATE_FILE" 2>/dev/null || echo "(missing)")
  echo "  ${RED}Timeout after ${timeout}s: state is '$got', expected '$expected'${NC}"
  echo "--- uploader log ---"
  cat "$TMPDIR/uploader.log" 2>/dev/null || true
  return 1
}

# check_object_exists <mc_path>
check_object_exists() {
  local path="$1"
  if mc stat "$path" >/dev/null 2>&1; then
    echo "  ${GREEN}OK${NC}: $path"
    return 0
  else
    echo "  ${RED}FAIL${NC}: $path not found"
    return 1
  fi
}

# check_object_absent <mc_path>
check_object_absent() {
  local path="$1"
  if mc stat "$path" >/dev/null 2>&1; then
    echo "  ${RED}FAIL${NC}: $path exists but should not"
    return 1
  else
    echo "  ${GREEN}OK${NC}: $path absent (expected)"
    return 0
  fi
}

# ── Start MinIO ───────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting MinIO ===${NC}"

MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  minio server --address "127.0.0.1:$MINIO_PORT" "$MINIO_DATA" \
  >"$TMPDIR/minio.log" 2>&1 &
MINIO_PID=$!
PIDS+=($MINIO_PID)

wait_for_port "$MINIO_PORT" 10 "MinIO"

mc alias set local "http://127.0.0.1:$MINIO_PORT" minioadmin minioadmin \
  --api S3v4 >/dev/null 2>&1
mc mb "local/$BUCKET_NAME" >/dev/null
echo "  Bucket created: $BUCKET_NAME"

BUCKET="local/$BUCKET_NAME/$S3_PREFIX"

# ── Phase 1: Basic uploads ────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Phase 1: Basic uploads ===${NC}"

# Copy chunks 0-3.  Chunk 3 is the tip and must be excluded; chunks 0-2 should
# be uploaded, leaving state = 2.
for n in 0 1 2 3; do copy_chunk "$n" "$IMMUTABLE_DIR"; done
echo "  Copied chunks 0-3 (tip: 3, expected uploads: 0, 1, 2)"

UPLOADER_PID=$(start_uploader "$TMPDIR/uploader.log")
PIDS+=($UPLOADER_PID)
echo "  chunk-uploader started (pid $UPLOADER_PID)"

wait_for_state "2" "$UPLOADER_PID"
kill "$UPLOADER_PID" 2>/dev/null || true
wait "$UPLOADER_PID" 2>/dev/null || true

echo "  Verifying uploaded objects..."
PHASE1_OK=true
for n in 0 1 2; do
  base=$(chunk_base "$n")
  for ext in chunk primary secondary; do
    check_object_exists "${BUCKET}${base}.${ext}" || PHASE1_OK=false
  done
done

echo "  Verifying tip (chunk 3) was not uploaded..."
check_object_absent "${BUCKET}$(chunk_base 3).chunk" || PHASE1_OK=false

if [[ "$PHASE1_OK" != "true" ]]; then
  echo "  ${RED}FAIL${NC}: Phase 1 checks failed"
  exit 1
fi
echo "  ${GREEN}Phase 1 passed${NC}"

# ── Phase 2: Resumption ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Phase 2: Resumption ===${NC}"

# Add chunks 4-5.  Now the tip is 5; chunks 3-4 are newly completed and should
# be uploaded on restart, leaving state = 4.
for n in 4 5; do copy_chunk "$n" "$IMMUTABLE_DIR"; done
echo "  Added chunks 4-5 (new tip: 5, expected new uploads: 3, 4)"

UPLOADER_PID=$(start_uploader "$TMPDIR/uploader.log")
PIDS+=($UPLOADER_PID)
echo "  chunk-uploader restarted (pid $UPLOADER_PID)"

wait_for_state "4" "$UPLOADER_PID"
kill "$UPLOADER_PID" 2>/dev/null || true
wait "$UPLOADER_PID" 2>/dev/null || true

echo "  Verifying newly uploaded objects..."
PHASE2_OK=true
for n in 3 4; do
  base=$(chunk_base "$n")
  for ext in chunk primary secondary; do
    check_object_exists "${BUCKET}${base}.${ext}" || PHASE2_OK=false
  done
done

echo "  Verifying previously uploaded objects still present..."
for n in 0 1 2; do
  base=$(chunk_base "$n")
  check_object_exists "${BUCKET}${base}.chunk" || PHASE2_OK=false
done

echo "  Verifying new tip (chunk 5) was not uploaded..."
check_object_absent "${BUCKET}$(chunk_base 5).chunk" || PHASE2_OK=false

if [[ "$PHASE2_OK" != "true" ]]; then
  echo "  ${RED}FAIL${NC}: Phase 2 checks failed"
  exit 1
fi
echo "  ${GREEN}Phase 2 passed${NC}"

# ── Phase 3: tip.json generation ──────────────────────────────────────────────

echo ""
echo "${BOLD}=== Phase 3: tip.json generation ===${NC}"

# Set up mock node config.
mkdir -p "$TMPDIR/config"
cp "$SCRIPT_DIR/config/"*.json "$TMPDIR/config/"
NODE_CONFIG="$TMPDIR/config/config.json"

# Add chunk 6. New tip is 6, chunk 5 is now completed and should be uploaded.
copy_chunk 6 "$IMMUTABLE_DIR"
echo "  Added chunk 6 (new tip: 6, expected new upload: 5)"

UPLOADER_PID=$(start_uploader "$TMPDIR/uploader-tip.log" "$NODE_CONFIG")
PIDS+=($UPLOADER_PID)
echo "  chunk-uploader started with --config (pid $UPLOADER_PID)"

wait_for_state "5" "$UPLOADER_PID"
kill "$UPLOADER_PID" 2>/dev/null || true
wait "$UPLOADER_PID" 2>/dev/null || true

echo "  Verifying tip.json was uploaded..."
PHASE3_OK=true
TIP_OBJECT="${BUCKET}tip.json"
check_object_exists "$TIP_OBJECT" || PHASE3_OK=false

if [[ "$PHASE3_OK" == "true" ]]; then
  echo "  Validating tip.json content..."
  TIP_JSON=$(mc cat "$TIP_OBJECT")
  echo "  Content: $TIP_JSON"
  
  # Check for required fields using jq.
  SLOT=$(echo "$TIP_JSON" | jq -r '.slot')
  BLOCK=$(echo "$TIP_JSON" | jq -r '.block_no')
  HASH=$(echo "$TIP_JSON" | jq -r '.hash')

  if [[ "$SLOT" =~ ^[0-9]+$ ]] && [[ "$BLOCK" =~ ^[0-9]+$ ]] && [[ -n "$HASH" ]]; then
    echo "  ${GREEN}OK${NC}: tip.json has valid fields (slot=$SLOT, block=$BLOCK)"
  else
    echo "  ${RED}FAIL${NC}: tip.json has invalid content"
    PHASE3_OK=false
  fi
fi

if [[ "$PHASE3_OK" != "true" ]]; then
  echo "  ${RED}FAIL${NC}: Phase 3 checks failed"
  echo "--- uploader log ---"
  cat "$TMPDIR/uploader-tip.log" 2>/dev/null || true
  exit 1
fi
echo "  ${GREEN}Phase 3 passed${NC}"

# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
