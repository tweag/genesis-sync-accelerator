#!/usr/bin/env bash
#
# Walk a synced ImmutableDB with `block-features` (our own ouroboros-consensus
# walker) and emit per-block features as CSV:
#
#   block_no,slot,hash,header_size,block_size,num_txs,txs_size,num_tx_outputs
#
# `block-features` reuses the HasAnalysis typeclass from
# ouroboros-consensus-cardano:unstable-cardano-tools, so it picks up Byron's
# and the Shelley-eras' tx-extraction logic without us re-implementing it.
#
# Usage:
#   extract-features.sh <node-db> <config.json> <out-csv>
#
# Must be invoked inside `nix develop` (default dev shell) with `cabal build
# exe:block-features` already run, OR with the binary on PATH.

set -euo pipefail

DB="${1:?node-db path required}"
CONFIG="${2:?config.json path required}"
OUT="${3:?output csv path required}"

# Locate the binary: prefer cabal's dist-newstyle build, fall back to PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BLOCK_FEATURES=""
if [[ -x "$REPO_ROOT/dist-newstyle" ]] || [[ -d "$REPO_ROOT/dist-newstyle" ]]; then
  BLOCK_FEATURES="$(find "$REPO_ROOT/dist-newstyle" -type f -name 'block-features' -executable 2>/dev/null | head -1)"
fi
if [[ -z "$BLOCK_FEATURES" ]] && command -v block-features >/dev/null 2>&1; then
  BLOCK_FEATURES="$(command -v block-features)"
fi
if [[ -z "$BLOCK_FEATURES" ]]; then
  echo "block-features not found." >&2
  echo "Build it first: nix develop -c cabal build exe:block-features" >&2
  exit 1
fi

echo "  block-features: $BLOCK_FEATURES"
# block-features mounts its --db argument directly as the ImmutableDB
# filesystem (same convention as tools/immdb-get-tip.hs + Util.fpToHasFS).
# `extract-features.sh` accepts the ChainDB root for symmetry with db-analyser
# and the rest of the harness, so we append `/immutable` here.
IMM_DIR="$DB/immutable"
[[ -d "$IMM_DIR" ]] || { echo "no immutable/ dir under $DB" >&2; exit 1; }
"$BLOCK_FEATURES" --db "$IMM_DIR" --config "$CONFIG" --progress-every 100000 > "$OUT"
echo "  wrote $(($(wc -l < "$OUT") - 1)) rows to $OUT"
