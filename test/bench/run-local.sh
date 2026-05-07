#!/usr/bin/env bash
#
# Local reproduction harness for the BlockFetch stall observed on EC2.
#
# Drives a full GSA + cardano-node setup against a local MinIO, seeded
# from a csnapshots.io Cardano mainnet ImmutableDB. Designed for fast
# iteration: tear down and re-run freely by removing the workdir.
#
# Usage:
#   nix develop .#integration-test
#   bash test/bench/run-local.sh
#
# Environment (sensible defaults; override as needed):
#   SNAPSHOT_DB       Extracted snapshot immutable dir (default: ~/gsa-snapshot/db/immutable)
#   WORKDIR           Per-run state: logs, gsa-cache, node-db (default: ~/gsa-snapshot/local-run)
#   CONFIG_DIR        Cardano network configs (default: ~/gsa-snapshot/config)
#   MINIO_DATA        MinIO backing store (default: ~/gsa-snapshot/minio-data)
#   MINIO_PORT        MinIO S3 API (default: 9100)
#   GSA_PORT          GSA listen port (default: 8781)
#   NODE_PORT         cardano-node port (default: 8782)
#   NETWORK           Cardano network (default: mainnet)
#   SKIP_SEED         1 to skip MinIO seeding (assumes already seeded)
#   MAX_CACHED_CHUNKS Defaults: 20
#   PREFETCH_AHEAD    Defaults: 1
#   STOP_AFTER_CHUNKS Halt once node-db/immutable has this many chunks (default: 5)
#   STOP_AT_TIP_SLOT  Halt once cardano-node tip slot reaches/exceeds this (default: unset)
#   STALL_TIMEOUT     Hard ceiling in seconds for the monitor loop (default: 1800)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../cdn/lib.sh"
source "$SCRIPT_DIR/../integration/lib.sh"
source "$SCRIPT_DIR/../benchmark/lib.sh"

# ── Config ───────────────────────────────────────────────────────────────────

SNAPSHOT_DB="${SNAPSHOT_DB:-$HOME/gsa-snapshot/db/immutable}"
WORKDIR="${WORKDIR:-$HOME/gsa-snapshot/local-run}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/gsa-snapshot/config}"
MINIO_DATA="${MINIO_DATA:-$HOME/gsa-snapshot/minio-data}"
MINIO_PORT="${MINIO_PORT:-9100}"
MINIO_CONSOLE_PORT=$((MINIO_PORT + 1))
GSA_PORT="${GSA_PORT:-8781}"
NODE_PORT="${NODE_PORT:-8782}"
NETWORK="${NETWORK:-mainnet}"
SKIP_SEED="${SKIP_SEED:-0}"
MAX_CACHED_CHUNKS="${MAX_CACHED_CHUNKS:-20}"
PREFETCH_AHEAD="${PREFETCH_AHEAD:-1}"
STOP_AFTER_CHUNKS="${STOP_AFTER_CHUNKS:-5}"
STOP_AT_TIP_SLOT="${STOP_AT_TIP_SLOT:-}"
STALL_TIMEOUT="${STALL_TIMEOUT:-1800}"

MINIO_USER="minioadmin"
MINIO_PASS="minioadmin"
BUCKET="chunks"
PREFIX="immutable/"

MC_CONFIG="$WORKDIR/mc-config"
GSA_CACHE="$WORKDIR/gsa-cache"
NODE_DB="$WORKDIR/node-db"
GSA_LOG="$WORKDIR/gsa.log"
NODE_LOG="$WORKDIR/node.log"
MINIO_LOG="$WORKDIR/minio.log"
UPLOADER_LOG="$WORKDIR/uploader.log"
UPLOADER_STATE="$WORKDIR/uploader.state"
TOPOLOGY="$WORKDIR/topology.json"
GSA_CONFIG="$WORKDIR/gsa-config.yaml"

CONFIG_JSON="$CONFIG_DIR/config.json"
PEER_SNAPSHOT="$CONFIG_DIR/peer-snapshot.json"

# ── Preflight ────────────────────────────────────────────────────────────────

echo "${BOLD}=== Preflight ===${NC}"
for cmd in genesis-sync-accelerator cardano-node chunk-uploader minio mc curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "${RED}Required command not found: $cmd${NC}"
    echo "Enter the dev shell first: nix develop .#integration-test"
    exit 1
  fi
done

# Kill any orphan GSA / cardano-node from earlier aborted runs in this workdir.
# setsid makes children survive parent death; a stale GSA on :$GSA_PORT would
# race the fresh one for inbound connections and silently win some of them.
for prev in $(pgrep -f "genesis-sync-accelerator.*--port $GSA_PORT" 2>/dev/null || true) \
            $(pgrep -f "cardano-node run.*--port $NODE_PORT" 2>/dev/null || true); do
  echo "  killing stale pid $prev"
  kill -- -"$prev" 2>/dev/null || kill "$prev" 2>/dev/null || true
done

# SNAPSHOT_DB is only needed if we have to re-seed MinIO. With SKIP_SEED=1
# (or after the bucket has been seeded once) the local snapshot can be
# garbage-collected to free disk; the harness will read from MinIO.
if [[ -d "$SNAPSHOT_DB" ]]; then
  SNAPSHOT_CHUNKS=$(find "$SNAPSHOT_DB" -maxdepth 1 -name '*.chunk' | wc -l)
  echo "  Snapshot immutable/ at $SNAPSHOT_DB has $SNAPSHOT_CHUNKS chunks"
elif [[ "$SKIP_SEED" == "1" ]]; then
  SNAPSHOT_CHUNKS=0
  echo "  SNAPSHOT_DB missing but SKIP_SEED=1 — assuming MinIO already populated"
else
  echo "${RED}SNAPSHOT_DB not found: $SNAPSHOT_DB${NC}"
  echo "  Set SKIP_SEED=1 if MinIO is already seeded and you don't need the local snapshot."
  exit 1
fi

mkdir -p "$WORKDIR" "$MC_CONFIG" "$GSA_CACHE" "$NODE_DB" "$CONFIG_DIR" "$MINIO_DATA"

# ── Cleanup ──────────────────────────────────────────────────────────────────

PIDS=()
cleanup() {
  echo ""
  echo "=== Cleanup ==="
  for pid in "${PIDS[@]:-}"; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "  Stopping pgroup $pid"
      kill -- -"$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

# ── MinIO (reuse if already running) ─────────────────────────────────────────

echo ""
echo "${BOLD}=== MinIO ===${NC}"
if curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1; then
  echo "  MinIO already healthy on :$MINIO_PORT (reusing)"
else
  MINIO_PID=$(start_minio "$MINIO_DATA" "$MINIO_PORT" "$MINIO_CONSOLE_PORT" \
              "$MINIO_USER" "$MINIO_PASS" "$MINIO_LOG")
  PIDS+=("$MINIO_PID")
  echo "  MinIO started (pid $MINIO_PID, log: $MINIO_LOG)"
  wait_for_minio "$MINIO_PORT" 20
fi

MC_CONFIG_DIR="$MC_CONFIG" mc alias set local "http://127.0.0.1:${MINIO_PORT}" \
  "$MINIO_USER" "$MINIO_PASS" --api S3v4 >/dev/null 2>&1
MC_CONFIG_DIR="$MC_CONFIG" mc mb --ignore-existing "local/$BUCKET" >/dev/null 2>&1 || true
# GSA fetches via plain HTTP with no auth; make the bucket world-readable.
MC_CONFIG_DIR="$MC_CONFIG" mc anonymous set download "local/$BUCKET" >/dev/null 2>&1 \
  || MC_CONFIG_DIR="$MC_CONFIG" mc policy set download "local/$BUCKET" >/dev/null 2>&1 \
  || true

# ── Fetch Cardano configs (one-shot, cached) ─────────────────────────────────

echo ""
echo "${BOLD}=== Cardano configs ===${NC}"
CONFIG_URL="https://book.world.dev.cardano.org/environments/$NETWORK"
for f in config.json topology.json byron-genesis.json shelley-genesis.json \
         alonzo-genesis.json conway-genesis.json checkpoints.json peer-snapshot.json; do
  if [[ -f "$CONFIG_DIR/$f" ]]; then
    echo "  have $f"
  else
    echo "  fetching $f"
    if ! curl -sSfL "$CONFIG_URL/$f" -o "$CONFIG_DIR/$f"; then
      if [[ "$f" == "checkpoints.json" || "$f" == "peer-snapshot.json" ]]; then
        echo "    (optional, skipped)"
      else
        echo "${RED}failed to fetch $f${NC}"
        exit 1
      fi
    fi
  fi
done

# Patch config.json once (idempotent no-op if already applied).
if ! grep -q '"ConsensusMode": "GenesisMode"' "$CONFIG_JSON"; then
  sed -i 's/"ConsensusMode":[^,]*/"ConsensusMode": "GenesisMode"/' "$CONFIG_JSON" 2>/dev/null || true
fi
sed -i 's/"EnableP2P":[[:space:]]*false/"EnableP2P": true/' "$CONFIG_JSON"
for flag in TraceChainDb TraceBlockFetchClient TraceBlockFetchDecisions TraceChainSyncClient TraceConnectionManager TracePeerSelection; do
  sed -i "s/\"$flag\":[[:space:]]*false/\"$flag\": true/" "$CONFIG_JSON"
done

# ── Seed MinIO from snapshot (skip if bucket already matches) ────────────────

if [[ "$SKIP_SEED" != "1" ]]; then
  echo ""
  echo "${BOLD}=== Seeding MinIO ===${NC}"
  MINIO_CHUNK_COUNT=$(count_minio_chunks "$BUCKET" "$PREFIX" "$MC_CONFIG")
  echo "  bucket has $MINIO_CHUNK_COUNT chunks / snapshot has $SNAPSHOT_CHUNKS"

  if (( MINIO_CHUNK_COUNT < SNAPSHOT_CHUNKS - 1 )); then
    echo "  running chunk-uploader against snapshot (+ tip.json via --config)…"
    AWS_ACCESS_KEY_ID="$MINIO_USER" \
    AWS_SECRET_ACCESS_KEY="$MINIO_PASS" \
      setsid stdbuf -oL chunk-uploader \
        --immutable-dir "$SNAPSHOT_DB" \
        --s3-bucket "$BUCKET" \
        --s3-prefix "$PREFIX" \
        --s3-endpoint "http://127.0.0.1:${MINIO_PORT}" \
        --s3-region us-east-1 \
        --poll-interval 3600 \
        --state-file "$UPLOADER_STATE" \
        --config "$CONFIG_JSON" \
        >"$UPLOADER_LOG" 2>&1 &
    UPLOADER_PID=$!
    PIDS+=("$UPLOADER_PID")
    echo "  chunk-uploader pid $UPLOADER_PID (log: $UPLOADER_LOG)"

    # Wait for upload to complete (last chunk excluded + tip.json uploaded).
    while true; do
      sleep 10
      NOW=$(count_minio_chunks "$BUCKET" "$PREFIX" "$MC_CONFIG")
      echo "  uploaded: $NOW / $((SNAPSHOT_CHUNKS - 1))"
      if (( NOW >= SNAPSHOT_CHUNKS - 1 )); then break; fi
      kill -0 "$UPLOADER_PID" 2>/dev/null || { echo "${RED}uploader died${NC}"; tail -30 "$UPLOADER_LOG"; exit 1; }
    done

    # Also manually upload the tail chunk (chunk-uploader excludes it as "not sealed").
    LAST_CHUNK=$(ls "$SNAPSHOT_DB"/*.chunk | sort | tail -1)
    LAST_BASE=$(basename "$LAST_CHUNK" .chunk)
    echo "  copying tail chunk triplet ${LAST_BASE} via mc"
    for ext in chunk primary secondary; do
      [[ -f "$SNAPSHOT_DB/${LAST_BASE}.${ext}" ]] && \
        MC_CONFIG_DIR="$MC_CONFIG" mc cp -q \
          "$SNAPSHOT_DB/${LAST_BASE}.${ext}" \
          "local/$BUCKET/${PREFIX}${LAST_BASE}.${ext}" >/dev/null
    done

    # Verify tip.json present.
    MC_CONFIG_DIR="$MC_CONFIG" mc stat "local/$BUCKET/${PREFIX}tip.json" >/dev/null \
      || { echo "${RED}tip.json not uploaded${NC}"; exit 1; }
    echo "  ${GREEN}seed OK${NC} (chunks + tip.json present)"
  else
    echo "  bucket already populated (≥ $((SNAPSHOT_CHUNKS - 1)) chunks), skipping"
  fi
fi

# ── Write gsa-config.yaml ────────────────────────────────────────────────────

cat > "$GSA_CONFIG" <<EOF
max-cached-chunks: $MAX_CACHED_CHUNKS
prefetch-ahead: $PREFETCH_AHEAD
rts-frequency: 2000
tip-refresh-interval: 600
EOF

# ── Write topology.json ─────────────────────────────────────────────────────

cat > "$TOPOLOGY" <<EOF
{
  "localRoots": [{
    "accessPoints": [{"address": "127.0.0.1", "port": $GSA_PORT}],
    "advertise": false,
    "trustable": true,
    "hotValency": 1,
    "warmValency": 1
  }],
  "bootstrapPeers": null,
  "peerSnapshotFile": "$PEER_SNAPSHOT",
  "publicRoots": [],
  "useLedgerAfterSlot": 0
}
EOF

# ── Start GSA ───────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== GSA ===${NC}"
GSA_PID=$(start_accelerator \
  "$GSA_CONFIG" \
  "$CONFIG_JSON" \
  "http://127.0.0.1:${MINIO_PORT}/${BUCKET}/${PREFIX%/}" \
  "$GSA_PORT" \
  "$GSA_CACHE" \
  "$GSA_LOG")
PIDS+=("$GSA_PID")
echo "  GSA pid $GSA_PID (log: $GSA_LOG)"
wait_for_port "$GSA_PORT" 30 "GSA"

# ── Start cardano-node ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}=== cardano-node ===${NC}"
NODE_PID=$(start_cardano_node \
  "$CONFIG_JSON" \
  "$NODE_DB" \
  "$TOPOLOGY" \
  "$NODE_PORT" \
  "$WORKDIR/node.sock" \
  "$NODE_LOG")
PIDS+=("$NODE_PID")
echo "  cardano-node pid $NODE_PID (log: $NODE_LOG)"

# ── Monitor ──────────────────────────────────────────────────────────────────

echo ""
if [[ -n "$STOP_AT_TIP_SLOT" ]]; then
  echo "${BOLD}=== Monitoring (stop at tip slot $STOP_AT_TIP_SLOT, or $STOP_AFTER_CHUNKS chunks) ===${NC}"
else
  echo "${BOLD}=== Monitoring (stop after $STOP_AFTER_CHUNKS written chunks) ===${NC}"
fi

START=$(date +%s)

while true; do
  sleep 5
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))
  NODE_CHUNKS=$(find "$NODE_DB/immutable" -maxdepth 1 -name '*.chunk' 2>/dev/null | wc -l)
  GSA_CACHE_CHUNKS=$(find "$GSA_CACHE" -maxdepth 1 -name '*.chunk' 2>/dev/null | wc -l)
  # grep -c always prints a number; `|| true` just swallows the exit-1 for no-match.
  # Note: TraceBlockFetchServerSendBlock was silenced in the GSA tracer
  # (commit 12abd0b "perf: silence per-message ChainSync/BlockFetch tracers"),
  # so we can't count served blocks directly anymore. TraceDownloadSuccess is
  # the closest substitute: GSA fetched a chunk file from the CDN and is now
  # serving from local cache.
  GSA_DL_OK=$(grep -c 'TraceDownloadSuccess' "$GSA_LOG" 2>/dev/null || true)
  STARVED=$(grep -c 'PeerStarvedUs' "$NODE_LOG" 2>/dev/null || true)
  TIP_SLOT=$(extract_tip_slot "$NODE_LOG")

  printf "  +%04ds  node_chunks=%d gsa_cache=%d gsa_dl_ok=%d starved=%d tip_slot=%s\n" \
    "$ELAPSED" "$NODE_CHUNKS" "$GSA_CACHE_CHUNKS" "${GSA_DL_OK:-0}" "${STARVED:-0}" "${TIP_SLOT:-0}" || true

  if (( NODE_CHUNKS >= STOP_AFTER_CHUNKS )); then
    echo "  ${GREEN}reached $STOP_AFTER_CHUNKS chunks on node side — success${NC}"
    break
  fi

  if [[ -n "$STOP_AT_TIP_SLOT" ]] && (( TIP_SLOT >= STOP_AT_TIP_SLOT )); then
    echo "  ${GREEN}reached tip slot $TIP_SLOT (≥ $STOP_AT_TIP_SLOT) — success${NC}"
    break
  fi

  if ! kill -0 "$GSA_PID" 2>/dev/null; then
    echo "${RED}GSA died${NC}"; tail -40 "$GSA_LOG"; exit 1
  fi
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    echo "${RED}node died${NC}"; tail -40 "$NODE_LOG"; exit 1
  fi

  if (( ELAPSED >= STALL_TIMEOUT )); then
    echo "${RED}timeout after ${STALL_TIMEOUT}s — stall suspected${NC}"
    echo "--- last 30 GSA ---"; grep -v '^Resources' "$GSA_LOG" | tail -30 | cut -c1-180
    echo "--- last 30 node ---"; tail -30 "$NODE_LOG" | cut -c1-180
    exit 1
  fi
done

echo ""
echo "${GREEN}${BOLD}=== DONE ===${NC}"
echo "  work dir: $WORKDIR"
echo "  keep MinIO running for subsequent runs (fresh WORKDIR) by: rm -rf $WORKDIR && bash $0 SKIP_SEED=1"
