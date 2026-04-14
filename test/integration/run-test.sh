#!/usr/bin/env bash
#
# Integration test for genesis-sync-accelerator.
#
# Ensures source ImmutableDB data exists (via chain-init.sh), serves it over
# a local HTTP server, runs the accelerator, connects a consumer cardano-node,
# waits for the consumer to sync, validates accelerator participation (CDN
# downloads, ChainSync interaction, BlockFetch from accelerator), checks cache
# integrity for present files, and verifies the consumer received the correct
# number of blocks using db-analyser.
#
# Usage:
#   nix develop .#integration-test
#   bash test/integration/run-test.sh
#
# Demo mode (tmux UI with live logs):
#   DEMO=1 bash test/integration/run-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Hook A: Demo bootstrap ──────────────────────────────────────────────────

if demo_is_active; then
  demo_require_tmux
  demo_reexec_in_tmux
fi

# ── Configuration ────────────────────────────────────────────────────────────

# Ports changed from 3001 to avoid a clash with an existing service on the Tweag
# builder. Picked randomly, but consistent to avoid introducing randomness.
CDN_PORT="${CDN_PORT:-8780}"
ACCEL_PORT="${ACCEL_PORT:-8781}"
CONSUMER_PORT="${CONSUMER_PORT:-8782}"
MIN_CHUNKS="${MIN_CHUNKS:-20}"
GSA_CONFIG="$SCRIPT_DIR/config.yaml"
POLL_INTERVAL=5
LOG_TAIL_LINES=50
SOURCE_DB="${DB_DIR:-$SCRIPT_DIR/test-data/source-db}"
CONFIG="$SCRIPT_DIR/config/config.json"
GSA="${GSA:-genesis-sync-accelerator}"
# Experiments: set these env vars to toggle behaviour.
#   CONSENSUS_MODE=PraosMode  — override GenesisMode (disables historicity check)
CONSENSUS_MODE="${CONSENSUS_MODE:-}"

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

# ── Ensure source data ──────────────────────────────────────────────────────

echo "${BOLD}=== Ensuring source data ===${NC}"

MIN_CHUNKS="$MIN_CHUNKS" DB_DIR="$SOURCE_DB" bash "$SCRIPT_DIR/chain-init.sh"

IMMUTABLE_SRC="$SOURCE_DB/immutable"
echo "  Source has $(find "$IMMUTABLE_SRC" -name '*.chunk' | wc -l) chunk(s)"

# ── Ephemeral workdir ────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t gsa-test.XXXXXX)"
ACCEL_CACHE="$TMPDIR/accel-cache"
CONSUMER_DB="$TMPDIR/consumer-db"
CDN_DATA="$TMPDIR/cdn-data"
mkdir -p "$ACCEL_CACHE" "$CONSUMER_DB" "$CDN_DATA"
echo "  Workdir: $TMPDIR"

# Copy the tip file to the CDN data folder so the accelerator can read it.
cp "$SCRIPT_DIR/tip.json" "$CDN_DATA/tip.json"

# Copy only the first MIN_CHUNKS chunk triplets to serve from the CDN.
# This keeps the test fast and avoids stale-data issues with large source DBs.
for chunk_file in $(ls "$IMMUTABLE_SRC"/*.chunk 2>/dev/null | sort | head -n "$MIN_CHUNKS"); do
  base="$(basename "$chunk_file" .chunk)"
  for ext in chunk primary secondary; do
    cp "$IMMUTABLE_SRC/${base}.${ext}" "$CDN_DATA/"
  done
done
CHUNK_COUNT=$(find "$CDN_DATA" -name '*.chunk' | wc -l)
echo "  CDN will serve $CHUNK_COUNT chunk(s)"

# Count total blocks in the source data by dividing secondary index file sizes
# by the fixed entry size (see ouroboros-consensus Secondary.entrySize, and 
# section 8.2.2 of "The Cardano Consensus and Storage Layer" (Feb. 9, 2026).
SECONDARY_INDEX_ENTRY_SIZE=56  # = 8 (block offset) + 2 (header offset) + 2 (header size) + 4 (checksum) + 32 (header hash) + 8 (block or EEB)
EXPECTED_IMMUTABLE_BLOCKS_COUNT=0
# Total expected blocks is the sum of all secondary index file sizes, divided by the entry size.
# Divide on each loop iteration to reduce risk of overflow.
for f in "$CDN_DATA"/*.secondary; do
  EXPECTED_IMMUTABLE_BLOCKS_COUNT=$(( EXPECTED_IMMUTABLE_BLOCKS_COUNT + $(stat -c%s "$f") / SECONDARY_INDEX_ENTRY_SIZE ))
done
echo "  Expected ImmutableDB blocks: $EXPECTED_IMMUTABLE_BLOCKS_COUNT"

demo_is_active && demo_prompt "Source data ready. Press Enter to start components..."

# ── Experiment overrides ─────────────────────────────────────────────────────

if [[ -n "$CONSENSUS_MODE" ]]; then
  echo "  ${BOLD}Experiment:${NC} overriding ConsensusMode → $CONSENSUS_MODE"
  PATCHED_CONFIG="$TMPDIR/config.json"
  sed "s/\"ConsensusMode\": \"[^\"]*\"/\"ConsensusMode\": \"$CONSENSUS_MODE\"/" \
    "$CONFIG" > "$PATCHED_CONFIG"
  for f in byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
    cp "$SCRIPT_DIR/config/$f" "$TMPDIR/$f"
  done
  CONFIG="$PATCHED_CONFIG"
fi

# ── Start CDN ────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting CDN ===${NC}"

CDN_PID=$(start_cdn "$CDN_DATA" "$CDN_PORT" "$TMPDIR/cdn.log")
PIDS+=($CDN_PID)

wait_for_port "$CDN_PORT" 10 "CDN"

# Verify the CDN is actually serving chunk data.
CDN_TEST_FILE=$(ls "$CDN_DATA"/*.chunk 2>/dev/null | head -1)
if [[ -n "$CDN_TEST_FILE" ]]; then
  CDN_TEST_NAME="$(basename "$CDN_TEST_FILE")"
  CDN_TEST_SIZE=$(curl -sS "http://127.0.0.1:${CDN_PORT}/${CDN_TEST_NAME}" 2>/dev/null | wc -c || echo "0")
  SRC_SIZE=$(wc -c < "$CDN_TEST_FILE")
  if (( CDN_TEST_SIZE == SRC_SIZE )); then
    echo "  CDN health check: ${GREEN}OK${NC} (${CDN_TEST_NAME}: ${CDN_TEST_SIZE} bytes)"
  else
    echo "  CDN health check: ${RED}FAIL${NC} (${CDN_TEST_NAME}: got ${CDN_TEST_SIZE}, expected ${SRC_SIZE})"
    exit 1
  fi
fi

# ── Start accelerator ────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting accelerator ===${NC}"

ACCEL_PID=$(start_accelerator "$GSA_CONFIG" "$CONFIG" "http://127.0.0.1:${CDN_PORT}" "$ACCEL_PORT" "$ACCEL_CACHE" "$TMPDIR/accelerator.log")
PIDS+=($ACCEL_PID)

wait_for_port "$ACCEL_PORT" 15 "Accelerator"

# ── Hook B: Create demo layout (before consumer so CDN downloads are visible) ─

if demo_is_active; then
  touch "$TMPDIR/cdn.log" "$TMPDIR/accelerator.log" "$TMPDIR/node.log"
  demo_create_layout "$TMPDIR/cdn.log" "$TMPDIR/accelerator.log" "$TMPDIR/node.log"
fi

# ── Start consumer ────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting consumer ===${NC}"

CONSUMER_TOPOLOGY="$TMPDIR/consumer-topology.json"
jq --arg snap "$SCRIPT_DIR/config/peer-snapshot.json" \
   --argjson port "$ACCEL_PORT" \
   '.localRoots[0].accessPoints = [{"address": "127.0.0.1", "port": $port}]
   | .localRoots[0].trustable = true
   | .localRoots[0].valency = 1
   | .peerSnapshotFile = $snap' \
   "$SCRIPT_DIR/config/topology.json" > "$CONSUMER_TOPOLOGY"

CONSUMER_PID=$(start_consumer "$CONFIG" "$CONSUMER_DB" "$CONSUMER_TOPOLOGY" "$CONSUMER_PORT" "$TMPDIR/node.sock" "$TMPDIR/node.log")
PIDS+=($CONSUMER_PID)

# Give the consumer a moment to connect, then show early diagnostics (headless only).
if ! demo_is_active; then
  sleep 3
  echo "  Accelerator log (first 10 lines):"
  head -10 "$TMPDIR/accelerator.log" 2>/dev/null | sed 's/^/    /' || true
  echo "  Accelerator cache:"
  ls -la "$ACCEL_CACHE"/*.chunk 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (no chunks yet)"
fi

# ── Phase 1: Wait for consumer to sync ────────────────────────────────────────
#
# Poll the consumer's ImmutableDB block count by summing secondary index file
# sizes, the same way we computed EXPECTED_IMMUTABLE_BLOCKS_COUNT for the source.
# db-analyser can't run while the node holds the ChainDB lock, but the
# secondary index files are append-only and safe to stat.
CONSUMER_TIMEOUT="${CONSUMER_TIMEOUT:-300}"

echo ""
if demo_is_active; then
  echo "${BOLD}=== Waiting for consumer to sync ===${NC}"
else
  echo "${BOLD}=== Phase 1: Wait for consumer to sync ===${NC}"
fi
echo "  Waiting for >=${EXPECTED_IMMUTABLE_BLOCKS_COUNT} blocks in consumer ImmutableDB …"

ELAPSED=0
while (( ELAPSED < CONSUMER_TIMEOUT )); do
  CONSUMER_BLOCKS=0
  for f in "$CONSUMER_DB/immutable"/*.secondary; do
    [[ -f "$f" ]] || continue
    CONSUMER_BLOCKS=$(( CONSUMER_BLOCKS + $(stat -c%s "$f") / SECONDARY_INDEX_ENTRY_SIZE ))
  done

  # Hook C: Richer progress in demo mode
  CACHE_COUNT=$(ls "$ACCEL_CACHE"/*.chunk 2>/dev/null | wc -l)
  if demo_is_active; then
    echo "  ${ELAPSED}/${CONSUMER_TIMEOUT}s — ${CONSUMER_BLOCKS}/${EXPECTED_IMMUTABLE_BLOCKS_COUNT} blocks | Cache: ${CACHE_COUNT} chunks"
  else
    echo "  ${ELAPSED}/${CONSUMER_TIMEOUT}s — ${CONSUMER_BLOCKS}/${EXPECTED_IMMUTABLE_BLOCKS_COUNT} blocks in consumer ImmutableDB"
  fi

  if (( CONSUMER_BLOCKS >= EXPECTED_IMMUTABLE_BLOCKS_COUNT )); then
    echo "  ${GREEN}Consumer ImmutableDB has ${CONSUMER_BLOCKS} blocks${NC}"
    break
  fi

  # Check accelerator is still alive.
  if ! kill -0 "$ACCEL_PID" 2>/dev/null; then
    echo "  ${RED}Accelerator (pid $ACCEL_PID) died!${NC}"
    echo "--- accelerator log ---"
    cat "$TMPDIR/accelerator.log" 2>/dev/null || true
    exit 1
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if (( ELAPSED >= CONSUMER_TIMEOUT )); then
  echo "  ${RED}Timeout after ${CONSUMER_TIMEOUT}s (${CONSUMER_BLOCKS}/${EXPECTED_IMMUTABLE_BLOCKS_COUNT} blocks)${NC}"
  echo "--- consumer log (last 50 lines) ---"
  tail -"$LOG_TAIL_LINES" "$TMPDIR/node.log" 2>/dev/null || true
  exit 1
fi

# ── Hook D: Manual transition to validation ──────────────────────────────────

demo_is_active && demo_prompt "Sync complete. Press Enter to run validation..."

# ── Stop the consumer so db-analyser can open the ChainDB ────────────────────

if kill -0 "$CONSUMER_PID" 2>/dev/null; then
  kill "$CONSUMER_PID" 2>/dev/null || true
  wait "$CONSUMER_PID" 2>/dev/null || true
fi

# ── Hook E: Validation (demo routes to panes, headless runs inline) ──────────

if demo_is_active; then
  echo ""
  echo "${BOLD}=== Running validation ===${NC}"
  demo_run_checks_in_panes "$TMPDIR" "$ACCEL_CACHE" "$CDN_DATA" "$CONSUMER_DB" "$CONFIG" "$EXPECTED_IMMUTABLE_BLOCKS_COUNT"
  VALIDATION_RC=$?
else
  # ── Phase 2: Consumer validation (db-analyser) ─────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 2: Consumer validation (db-analyser) ===${NC}"

  check_block_count "$CONSUMER_DB" "$CONFIG" "$EXPECTED_IMMUTABLE_BLOCKS_COUNT" || exit 1

  # ── Phase 3: Validate accelerator participation ────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 3: Validate accelerator participation ===${NC}"

  PHASE3_OK=true
  check_cdn_downloads "$TMPDIR/cdn.log" || PHASE3_OK=false
  check_chainsync_messages "$TMPDIR/accelerator.log" || PHASE3_OK=false
  check_blockfetch_served "$TMPDIR/accelerator.log" || PHASE3_OK=false
  check_blockfetch_from_accel "$TMPDIR/node.log" || PHASE3_OK=false

  if [[ "$PHASE3_OK" != "true" ]]; then
    echo ""
    echo "--- accelerator log (last 50 lines) ---"
    tail -50 "$TMPDIR/accelerator.log" 2>/dev/null || true
    echo "--- consumer log (last 50 lines) ---"
    tail -50 "$TMPDIR/node.log" 2>/dev/null || true
    echo "--- CDN log (last 20 lines) ---"
    tail -20 "$TMPDIR/cdn.log" 2>/dev/null || true
    exit 1
  fi

  # ── Phase 4: Cache integrity ───────────────────────────────────────────────

  echo ""
  echo "${BOLD}=== Phase 4: Cache integrity ===${NC}"

  check_cache_integrity "$ACCEL_CACHE" "$CDN_DATA" || exit 1

  echo ""
  check_consumer_integrity "$CONSUMER_DB" "$CDN_DATA" || exit 1

  VALIDATION_RC=0
  echo ""
  echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
fi

# ── Hook F & G: Demo cleanup and exit ────────────────────────────────────────

if demo_is_active; then
  if (( VALIDATION_RC == 0 )); then
    demo_prompt "All checks passed. Press Enter to exit..."
  else
    demo_prompt "Some checks failed. Press Enter to exit..."
  fi
  # Kill the entire tmux session (this also kills all panes).
  tmux kill-session 2>/dev/null || true
fi

exit "${VALIDATION_RC:-0}"
