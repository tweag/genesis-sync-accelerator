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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Configuration ────────────────────────────────────────────────────────────

CDN_PORT=18080
ACCEL_PORT=13001
CONSUMER_PORT=13100
MIN_CHUNKS="${MIN_CHUNKS:-20}"
MAX_CACHED_CHUNKS=25
SOURCE_DB="${DB_DIR:-$SCRIPT_DIR/test-data/source-db}"
CONFIG="$SCRIPT_DIR/config/config.json"
CONSUMER_CONFIG="$SCRIPT_DIR/config/consumer-config.json"
GSA="${GSA:-genesis-sync-accelerator}"
# Experiments: set these env vars to toggle behaviour.
#   CONSENSUS_MODE=PraosMode  — override GenesisMode (disables historicity check)
CONSENSUS_MODE="${CONSENSUS_MODE:-}"

# ── Cleanup ──────────────────────────────────────────────────────────────────

PIDS=()
TMPDIR=""

cleanup() {
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
    echo "  Removing $TMPDIR"
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

# ── Ensure source data ──────────────────────────────────────────────────────

echo "${BOLD}=== Ensuring source data ===${NC}"

DB_DIR="$SOURCE_DB" bash "$SCRIPT_DIR/chain-init.sh"

IMMUTABLE_SRC="$SOURCE_DB/immutable"
echo "  Source has $(find "$IMMUTABLE_SRC" -name '*.chunk' | wc -l) chunk(s)"

# ── Ephemeral workdir ────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d -t gsa-test.XXXXXX)"
ACCEL_CACHE="$TMPDIR/accel-cache"
CONSUMER_DB="$TMPDIR/consumer-db"
CDN_DATA="$TMPDIR/cdn-data"
mkdir -p "$ACCEL_CACHE" "$CONSUMER_DB" "$CDN_DATA"
echo "  Workdir: $TMPDIR"

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
# by the fixed entry size (see ouroboros-consensus Secondary.entrySize).
SECONDARY_ENTRY_SIZE=56
TOTAL_BLOCKS=0
for f in "$CDN_DATA"/*.secondary; do
  TOTAL_BLOCKS=$(( TOTAL_BLOCKS + $(stat -c%s "$f") / SECONDARY_ENTRY_SIZE ))
done
echo "  Total blocks in source data: $TOTAL_BLOCKS"

# The consumer keeps the last k blocks in VolatileDB; only older blocks move to
# ImmutableDB.  db-analyser --count-blocks reads ImmutableDB only, so the
# expected count is (total - k).  Read k from the Shelley genesis file.
SECURITY_PARAM=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['securityParam'])" \
  "$SCRIPT_DIR/config/shelley-genesis.json")
EXPECTED_IMMUTABLE=$(( TOTAL_BLOCKS > SECURITY_PARAM ? TOTAL_BLOCKS - SECURITY_PARAM : 0 ))
echo "  Security parameter (k): $SECURITY_PARAM"
echo "  Expected ImmutableDB blocks (total - k): $EXPECTED_IMMUTABLE"


# ── Experiment overrides ─────────────────────────────────────────────────────

if [[ -n "$CONSENSUS_MODE" ]]; then
  echo "  ${BOLD}Experiment:${NC} overriding ConsensusMode → $CONSENSUS_MODE"
  # Patch consumer config in the ephemeral workdir so we don't modify the repo copy.
  # Copy genesis files too, since the config references them via relative paths.
  PATCHED_CONSUMER_CONFIG="$TMPDIR/consumer-config.json"
  sed "s/\"ConsensusMode\": \"[^\"]*\"/\"ConsensusMode\": \"$CONSENSUS_MODE\"/" \
    "$CONSUMER_CONFIG" > "$PATCHED_CONSUMER_CONFIG"
  for f in byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
    cp "$SCRIPT_DIR/config/$f" "$TMPDIR/$f"
  done
  CONSUMER_CONFIG="$PATCHED_CONSUMER_CONFIG"
fi

# ── Start CDN ────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting CDN ===${NC}"

python3 -m http.server "$CDN_PORT" --directory "$CDN_DATA" \
  >"$TMPDIR/cdn.log" 2>&1 &
PIDS+=($!)

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

# Force line-buffered stdout so we see trace output even if the accelerator
# is killed before Haskell's block buffer flushes.
stdbuf -oL $GSA \
  --db "$ACCEL_CACHE" \
  --config "$CONFIG" \
  --rs-src-url "http://127.0.0.1:${CDN_PORT}" \
  --rs-cache-url "$ACCEL_CACHE" \
  --port "$ACCEL_PORT" \
  --max-cached-chunks "$MAX_CACHED_CHUNKS" \
  >"$TMPDIR/accelerator.log" 2>&1 &
ACCEL_PID=$!
PIDS+=($ACCEL_PID)

wait_for_port "$ACCEL_PORT" 15 "Accelerator"

# ── Download peer snapshot ────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Downloading peer snapshot ===${NC}"

PEER_SNAPSHOT_URL="https://book.play.dev.cardano.org/environments/preprod/peer-snapshot.json"
curl -sSfL "$PEER_SNAPSHOT_URL" -o "$SCRIPT_DIR/config/peer-snapshot.json"
echo "  Downloaded peer-snapshot.json"

# ── Start consumer ────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== Starting consumer ===${NC}"

stdbuf -oL cardano-node run \
  --config "$CONSUMER_CONFIG" \
  --database-path "$CONSUMER_DB" \
  --topology "$SCRIPT_DIR/config/consumer-topology.json" \
  --port "$CONSUMER_PORT" \
  --socket-path "$TMPDIR/node.sock" \
  >"$TMPDIR/node.log" 2>&1 &
CONSUMER_PID=$!
PIDS+=($CONSUMER_PID)

# Give the consumer a moment to connect, then show early diagnostics.
sleep 3
echo "  Accelerator log (first 10 lines):"
head -10 "$TMPDIR/accelerator.log" 2>/dev/null | sed 's/^/    /' || true
echo "  Accelerator cache:"
ls -la "$ACCEL_CACHE"/*.chunk 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (no chunks yet)"

# ── Phase 1: Wait for consumer to sync ────────────────────────────────────────
#
# Poll the consumer's ImmutableDB block count by summing secondary index file
# sizes, the same way we computed TOTAL_BLOCKS for the source.  db-analyser
# can't run while the node holds the ChainDB lock, but the secondary index
# files are append-only and safe to stat.
CONSUMER_TIMEOUT="${CONSUMER_TIMEOUT:-300}"

echo ""
echo "${BOLD}=== Phase 1: Wait for consumer to sync ===${NC}"
echo "  Waiting for ≥${EXPECTED_IMMUTABLE} blocks in consumer ImmutableDB …"

ELAPSED=0
while (( ELAPSED < CONSUMER_TIMEOUT )); do
  CONSUMER_BLOCKS=0
  for f in "$CONSUMER_DB/immutable"/*.secondary; do
    [[ -f "$f" ]] || continue
    CONSUMER_BLOCKS=$(( CONSUMER_BLOCKS + $(stat -c%s "$f") / SECONDARY_ENTRY_SIZE ))
  done
  echo "  ${ELAPSED}/${CONSUMER_TIMEOUT}s — ${CONSUMER_BLOCKS}/${EXPECTED_IMMUTABLE} blocks in consumer ImmutableDB"

  if (( CONSUMER_BLOCKS >= EXPECTED_IMMUTABLE )); then
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

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if (( ELAPSED >= CONSUMER_TIMEOUT )); then
  echo "  ${RED}Timeout after ${CONSUMER_TIMEOUT}s (${CONSUMER_BLOCKS}/${EXPECTED_IMMUTABLE} blocks)${NC}"
  echo "--- consumer log (last 50 lines) ---"
  tail -50 "$TMPDIR/node.log" 2>/dev/null || true
  exit 1
fi

# ── Phase 2: Consumer validation (db-analyser) ───────────────────────────────

# Stop the consumer so db-analyser can open the ChainDB.
if kill -0 "$CONSUMER_PID" 2>/dev/null; then
  kill "$CONSUMER_PID" 2>/dev/null || true
  wait "$CONSUMER_PID" 2>/dev/null || true
fi

echo ""
echo "${BOLD}=== Phase 2: Consumer validation (db-analyser) ===${NC}"

DB_ANALYSER_OUT=$(db-analyser --db "$CONSUMER_DB" --config "$CONFIG" --count-blocks --v1-in-mem 2>&1) || true
BLOCK_COUNT=$(echo "$DB_ANALYSER_OUT" | grep -oP 'Counted \K[0-9]+' || echo "")

if [[ -z "$BLOCK_COUNT" ]]; then
  echo "  ${RED}FAIL${NC}: db-analyser did not report a block count"
  echo "--- db-analyser output ---"
  echo "$DB_ANALYSER_OUT"
  exit 1
fi

echo "  Consumer ImmutableDB: ${BLOCK_COUNT} blocks (expected ≥ ${EXPECTED_IMMUTABLE})"

if (( BLOCK_COUNT >= EXPECTED_IMMUTABLE )); then
  echo "  ${GREEN}OK${NC}: ${BLOCK_COUNT} blocks in ImmutableDB (≥ ${EXPECTED_IMMUTABLE})"
else
  echo "  ${RED}FAIL${NC}: Only ${BLOCK_COUNT} blocks in ImmutableDB (need ≥ ${EXPECTED_IMMUTABLE})"
  echo "--- db-analyser output ---"
  echo "$DB_ANALYSER_OUT"
  echo "--- consumer log (last 50 lines) ---"
  tail -50 "$TMPDIR/node.log" 2>/dev/null || true
  exit 1
fi

CHAIN_EXTENDED=$(grep -c 'Chain extended' "$TMPDIR/node.log" 2>/dev/null || echo "0")
echo "  Consumer adopted ${CHAIN_EXTENDED} chain extension(s)"
if (( CHAIN_EXTENDED == 0 )); then
  echo "  ${RED}FAIL${NC}: Consumer never extended its chain"
  exit 1
fi

# ── Phase 3: Validate accelerator participation ──────────────────────────────

echo ""
echo "${BOLD}=== Phase 3: Validate accelerator participation ===${NC}"

PHASE3_OK=true

# 3a. CDN downloads happened — count HTTP 200 responses in CDN log.
CDN_DOWNLOADS=$(grep -c '"GET .* HTTP/.*" 200' "$TMPDIR/cdn.log" 2>/dev/null || echo "0")
echo "  CDN HTTP 200 responses: ${CDN_DOWNLOADS}"
if (( CDN_DOWNLOADS > 0 )); then
  echo "  ${GREEN}OK${NC}: Accelerator downloaded data from CDN"
else
  echo "  ${RED}FAIL${NC}: No CDN downloads detected"
  PHASE3_OK=false
fi

# 3b. Accelerator served ChainSync data.
CHAINSYNC_MSGS=$(grep -cE 'MsgRollForward|MsgIntersectFound' "$TMPDIR/accelerator.log" 2>/dev/null || echo "0")
echo "  Accelerator ChainSync messages: ${CHAINSYNC_MSGS}"
if (( CHAINSYNC_MSGS > 0 )); then
  echo "  ${GREEN}OK${NC}: Accelerator served ChainSync data"
else
  echo "  ${RED}FAIL${NC}: No ChainSync interaction detected in accelerator log"
  PHASE3_OK=false
fi

# 3c. BlockFetch from accelerator — grep consumer log for CompletedBlockFetch
#     with the accelerator's address (127.0.0.1).
BLOCKFETCH_FROM_ACCEL=$(grep -c 'CompletedBlockFetch.*127\.0\.0\.1' "$TMPDIR/node.log" 2>/dev/null || echo "0")
echo "  BlockFetch completions from accelerator (127.0.0.1): ${BLOCKFETCH_FROM_ACCEL}"
if (( BLOCKFETCH_FROM_ACCEL > 0 )); then
  echo "  ${GREEN}OK${NC}: Blocks were fetched from the accelerator"
else
  echo "  ${RED}FAIL${NC}: No BlockFetch completions from accelerator detected"
  echo "  (Requires TraceBlockFetchClient: true in consumer config)"
  PHASE3_OK=false
fi

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

# ── Phase 4: Cache integrity ─────────────────────────────────────────────────
#
# Validate that whatever chunk files ARE present in the accelerator's cache
# match the source byte-for-byte.  We do NOT require all chunks to be cached
# (LRU eviction means old chunks may have been removed).

echo ""
echo "${BOLD}=== Phase 4: Cache integrity ===${NC}"

CACHED_CHUNKS=$(find "$ACCEL_CACHE" -maxdepth 1 -name '*.chunk' 2>/dev/null | wc -l)
echo "  Accelerator cache has ${CACHED_CHUNKS} chunk(s)"

INTEGRITY_OK=true
CHECKED=0
for cached_chunk in "$ACCEL_CACHE"/*.chunk; do
  [[ -f "$cached_chunk" ]] || continue
  base="$(basename "$cached_chunk" .chunk)"
  for ext in chunk primary secondary; do
    cached_file="$ACCEL_CACHE/${base}.${ext}"
    src_file="$CDN_DATA/${base}.${ext}"
    [[ -f "$cached_file" ]] || continue
    if [[ ! -f "$src_file" ]]; then
      echo "  ${RED}UNEXPECTED${NC}: ${base}.${ext} in cache but not in CDN source"
      INTEGRITY_OK=false
      continue
    fi
    src_sum=$(sha256sum "$src_file" | awk '{print $1}')
    cache_sum=$(sha256sum "$cached_file" | awk '{print $1}')
    if [[ "$src_sum" == "$cache_sum" ]]; then
      echo "  ${GREEN}OK${NC}: ${base}.${ext}"
    else
      echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
      INTEGRITY_OK=false
    fi
    CHECKED=$((CHECKED + 1))
  done
done

echo "  Checked ${CHECKED} file(s)"

if [[ "$INTEGRITY_OK" != "true" ]]; then
  echo "  ${RED}FAIL${NC}: Cache integrity check failed"
  exit 1
fi

if (( CHECKED == 0 )); then
  echo "  ${RED}FAIL${NC}: No cached files to verify"
  exit 1
fi

# Also verify the consumer's ImmutableDB chunk files match the source.
# Skip the highest-numbered consumer chunk — it may still be open for writing
# (the consumer appends blocks from real peers beyond our source data).
echo ""
echo "  Consumer ImmutableDB vs source:"
CONSUMER_LAST_CHUNK=$(ls "$CONSUMER_DB/immutable"/*.chunk 2>/dev/null | sort | tail -1)
CONSUMER_LAST_BASE=""
if [[ -n "$CONSUMER_LAST_CHUNK" ]]; then
  CONSUMER_LAST_BASE="$(basename "$CONSUMER_LAST_CHUNK" .chunk)"
fi

CONSUMER_CHECKED=0
for src_chunk in "$CDN_DATA"/*.chunk; do
  [[ -f "$src_chunk" ]] || continue
  base="$(basename "$src_chunk" .chunk)"
  # Skip the consumer's tip chunk — it may have been extended beyond the source.
  [[ "$base" == "$CONSUMER_LAST_BASE" ]] && continue
  for ext in chunk primary secondary; do
    consumer_file="$CONSUMER_DB/immutable/${base}.${ext}"
    src_file="$CDN_DATA/${base}.${ext}"
    [[ -f "$consumer_file" ]] || continue
    src_sum=$(sha256sum "$src_file" | awk '{print $1}')
    consumer_sum=$(sha256sum "$consumer_file" | awk '{print $1}')
    if [[ "$src_sum" == "$consumer_sum" ]]; then
      echo "  ${GREEN}OK${NC}: ${base}.${ext}"
    else
      echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
      INTEGRITY_OK=false
    fi
    CONSUMER_CHECKED=$((CONSUMER_CHECKED + 1))
  done
done

echo "  Checked ${CONSUMER_CHECKED} consumer file(s) (skipped tip chunk ${CONSUMER_LAST_BASE})"

if [[ "$INTEGRITY_OK" != "true" ]]; then
  echo "  ${RED}FAIL${NC}: Consumer integrity check failed"
  exit 1
fi

echo ""
echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
