#!/usr/bin/env bash
# Sync a cardano-node against preprod to populate a source ImmutableDB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MIN_CHUNKS="${MIN_CHUNKS:-10}"
TIMEOUT=600
DB_DIR="${DB_DIR:-./test-data/source-db}"
NODE_PORT=13713
CONFIG="$SCRIPT_DIR/config/config.json"
TOPOLOGY="$SCRIPT_DIR/config/topology.json"
IMMUTABLE_DIR="$DB_DIR/immutable"

command -v cardano-node >/dev/null || { echo "${RED}cardano-node not found.${NC} Run: nix develop .#integration-test"; exit 1; }

# Skip if already synced.
if [[ -d "$IMMUTABLE_DIR" ]]; then
  EXISTING=$(find "$IMMUTABLE_DIR" -name '*.chunk' 2>/dev/null | wc -l)
  if (( EXISTING >= MIN_CHUNKS )); then
    echo "Already have $EXISTING chunks (need $MIN_CHUNKS). Nothing to do."
    exit 0
  fi
fi

WORKDIR="$(dirname "$DB_DIR")"
mkdir -p "$WORKDIR" "$DB_DIR"

NODE_PID=""
trap 'if [[ -n "$NODE_PID" ]]; then kill -INT "$NODE_PID" 2>/dev/null; wait "$NODE_PID" 2>/dev/null; fi; rm -f "$WORKDIR/node.sock"' EXIT

cardano-node run \
  --config "$CONFIG" \
  --database-path "$DB_DIR" \
  --topology "$TOPOLOGY" \
  --port "$NODE_PORT" \
  --socket-path "$WORKDIR/node.sock" \
  >"$WORKDIR/node.log" 2>&1 &
NODE_PID=$!

echo "Syncing preprod (pid $NODE_PID, port $NODE_PORT, target >= $MIN_CHUNKS chunks)"

ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
  CHUNKS=0
  [[ -d "$IMMUTABLE_DIR" ]] && CHUNKS=$(find "$IMMUTABLE_DIR" -name '*.chunk' 2>/dev/null | wc -l)

  if (( CHUNKS >= MIN_CHUNKS )); then
    echo "${GREEN}Done:${NC} $CHUNKS chunks synced."
    kill -INT "$NODE_PID" 2>/dev/null; wait "$NODE_PID" 2>/dev/null; NODE_PID=""
    exit 0
  fi

  kill -0 "$NODE_PID" 2>/dev/null || { echo "${RED}Node died.${NC}"; tail -20 "$WORKDIR/node.log"; exit 1; }

  echo "  ${ELAPSED}s — $CHUNKS chunks"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "${RED}Timeout after ${TIMEOUT}s ($CHUNKS/$MIN_CHUNKS chunks)${NC}"
exit 1
