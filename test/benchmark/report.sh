#!/usr/bin/env bash
#
# Collect and display benchmark results from Phase 1 and Phase 2.
#
# Usage:
#   bash test/benchmark/report.sh
#
# Environment:
#   DATA_DIR    Data root (default: /data)
#   BUCKET      S3 bucket name (for display)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DATA_DIR="${DATA_DIR:-/data}"
BUCKET="${BUCKET:-unknown}"

# ── Helpers ──────────────────────────────────────────────────────────────────

# format_duration <seconds>
format_duration() {
  local secs="$1"
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  printf "%dh %02dm %02ds" "$h" "$m" "$s"
}

# time_to_epoch <ISO timestamp>
time_to_epoch() {
  date -d "$1" +%s 2>/dev/null || echo "0"
}

# ── Read timing data ────────────────────────────────────────────────────────

echo "${BOLD}=== Cardano Mainnet Sync Benchmark Results ===${NC}"
echo ""

# Metadata.
ENV_FILE="$DATA_DIR/benchmark.env"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

echo "Date:              $(date -u +%Y-%m-%d)"
echo "GSA Commit:        ${GSA_COMMIT:-unknown}"
echo "Instance Type:     ${INSTANCE_TYPE:-unknown}"
echo "Region:            ${AWS_REGION:-${REGION:-unknown}}"
echo "S3 Bucket:         $BUCKET"
echo ""

# ── Phase 1 ──────────────────────────────────────────────────────────────────

P1_START_FILE="$DATA_DIR/phase1/start-time"
P1_END_FILE="$DATA_DIR/phase1/end-time"
P1_CSV="$DATA_DIR/phase1/progress.csv"

echo "${BOLD}--- Phase 1: Baseline Sync + Chunk Upload ---${NC}"

if [[ -f "$P1_START_FILE" && -f "$P1_END_FILE" ]]; then
  P1_START=$(cat "$P1_START_FILE")
  P1_END=$(cat "$P1_END_FILE")
  P1_START_EPOCH=$(time_to_epoch "$P1_START")
  P1_END_EPOCH=$(time_to_epoch "$P1_END")
  P1_DURATION=$((P1_END_EPOCH - P1_START_EPOCH))

  echo "  Start:           $P1_START"
  echo "  End:             $P1_END"
  echo "  Duration:        $(format_duration $P1_DURATION)"

  # Final metrics from progress CSV.
  if [[ -f "$P1_CSV" ]]; then
    LAST_LINE=$(tail -1 "$P1_CSV")
    P1_BLOCKS=$(echo "$LAST_LINE" | cut -d, -f3)
    P1_CHUNKS=$(echo "$LAST_LINE" | cut -d, -f4)
    P1_TIP_SLOT=$(echo "$LAST_LINE" | cut -d, -f5)
    P1_UPLOADED=$(echo "$LAST_LINE" | cut -d, -f6)
    echo "  Final blocks:    $P1_BLOCKS"
    echo "  Final chunks:    $P1_CHUNKS"
    echo "  Tip slot:        $P1_TIP_SLOT"
    echo "  Uploaded:        $P1_UPLOADED"
  fi

  # ImmutableDB size.
  P1_IMMDB="$DATA_DIR/phase1/node-db/immutable"
  if [[ -d "$P1_IMMDB" ]]; then
    P1_SIZE=$(du -sh "$P1_IMMDB" 2>/dev/null | awk '{print $1}')
    echo "  ImmutableDB:     $P1_SIZE"
  fi
else
  echo "  ${RED}Phase 1 not completed${NC}"
  if [[ -f "$P1_START_FILE" ]]; then
    echo "  Started at:      $(cat "$P1_START_FILE")"
    echo "  (still running or interrupted)"
  else
    echo "  (not started)"
  fi
  P1_DURATION=0
fi

# ── Phase 2 ──────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Phase 2: GSA-Accelerated Sync ---${NC}"

P2_START_FILE="$DATA_DIR/phase2/start-time"
P2_END_FILE="$DATA_DIR/phase2/end-time"
P2_CSV="$DATA_DIR/phase2/progress.csv"

if [[ -f "$P2_START_FILE" && -f "$P2_END_FILE" ]]; then
  P2_START=$(cat "$P2_START_FILE")
  P2_END=$(cat "$P2_END_FILE")
  P2_START_EPOCH=$(time_to_epoch "$P2_START")
  P2_END_EPOCH=$(time_to_epoch "$P2_END")
  P2_DURATION=$((P2_END_EPOCH - P2_START_EPOCH))

  echo "  Start:           $P2_START"
  echo "  End:             $P2_END"
  echo "  Duration:        $(format_duration $P2_DURATION)"

  if [[ -f "$P2_CSV" ]]; then
    LAST_LINE=$(tail -1 "$P2_CSV")
    P2_BLOCKS=$(echo "$LAST_LINE" | cut -d, -f3)
    P2_CHUNKS=$(echo "$LAST_LINE" | cut -d, -f4)
    P2_TIP_SLOT=$(echo "$LAST_LINE" | cut -d, -f5)
    echo "  Final blocks:    $P2_BLOCKS"
    echo "  Final chunks:    $P2_CHUNKS"
    echo "  Tip slot:        $P2_TIP_SLOT"
  fi

  P2_IMMDB="$DATA_DIR/phase2/node-db/immutable"
  if [[ -d "$P2_IMMDB" ]]; then
    P2_SIZE=$(du -sh "$P2_IMMDB" 2>/dev/null | awk '{print $1}')
    echo "  ImmutableDB:     $P2_SIZE"
  fi
else
  echo "  ${RED}Phase 2 not completed${NC}"
  if [[ -f "$P2_START_FILE" ]]; then
    echo "  Started at:      $(cat "$P2_START_FILE")"
    echo "  (still running or interrupted)"
  else
    echo "  (not started)"
  fi
  P2_DURATION=0
fi

# ── Comparison ───────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Comparison ---${NC}"

if (( P1_DURATION > 0 && P2_DURATION > 0 )); then
  # Compute speedup with one decimal place.
  SPEEDUP=$(awk "BEGIN {printf \"%.1f\", $P1_DURATION / $P2_DURATION}")
  TIME_SAVED=$((P1_DURATION - P2_DURATION))

  echo "  Baseline:        $(format_duration $P1_DURATION)"
  echo "  GSA:             $(format_duration $P2_DURATION)"
  echo "  Speedup:         ${SPEEDUP}x"
  echo "  Time saved:      $(format_duration $TIME_SAVED)"
elif (( P1_DURATION > 0 )); then
  echo "  Baseline:        $(format_duration $P1_DURATION)"
  echo "  GSA:             (not yet available)"
else
  echo "  (insufficient data for comparison)"
fi

# ── Validation summary ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Chunk Uploader Validation ---${NC}"
echo "  Run: bash test/benchmark/validate.sh"

echo ""
