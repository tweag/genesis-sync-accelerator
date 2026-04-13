#!/usr/bin/env bash
# Shared helpers for the AWS benchmark scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

# ── Configuration defaults ──────────────────────────────────────────────────

DATA_DIR="${DATA_DIR:-/data}"
CONFIG_DIR="${CONFIG_DIR:-$DATA_DIR/config}"
REGION="${AWS_REGION:-us-east-1}"

# Mainnet slot arithmetic (for sync detection).
# Byron: 1 slot = 20s, epoch 0 starts at unix 1506203091.
# Shelley+: 1 slot = 1s, starts at slot 4492800 / unix 1596059091.
SHELLEY_START_SLOT=4492800
SHELLEY_START_UNIX=1596059091

# ImmutableDB secondary index entry size (bytes).
SECONDARY_INDEX_ENTRY_SIZE=56

# ── Slot / time helpers ─────────────────────────────────────────────────────

# expected_current_slot — compute the approximate current mainnet slot.
expected_current_slot() {
  local now
  now=$(date +%s)
  echo $(( SHELLEY_START_SLOT + now - SHELLEY_START_UNIX ))
}

# ── Sync detection ──────────────────────────────────────────────────────────

# extract_tip_slot <log_file>
#   Extract the most recent tip slot from cardano-node logs.
#   Parses AddedToCurrentChain / SwitchedToAFork trace lines.
extract_tip_slot() {
  local log_file="$1"
  # The legacy tracer (UseTraceDispatcher: false) emits lines like:
  #   ... "AddedToCurrentChain" ... "newtip":"<hash>@<slot>" ...
  # or with trace-dispatcher (UseTraceDispatcher: true):
  #   ... "slotNo":<N> ... in AddBlockEvent traces.
  # Try both patterns, take whichever yields the highest slot.
  local slot_legacy slot_new slot=0

  slot_legacy=$(grep -oP 'newtip":"[^"]*@\K[0-9]+' "$log_file" 2>/dev/null | tail -1)
  slot_new=$(grep -oP '"slotNo":\s*\K[0-9]+' "$log_file" 2>/dev/null | tail -1)

  [[ -n "$slot_legacy" ]] && (( slot_legacy > slot )) && slot=$slot_legacy
  [[ -n "$slot_new" ]] && (( slot_new > slot )) && slot=$slot_new
  echo "$slot"
}

# is_sync_complete <log_file> [max_lag_slots]
#   Returns 0 if the node's tip slot is within max_lag_slots of wall-clock.
#   Default max_lag_slots = 600 (~10 minutes).
is_sync_complete() {
  local log_file="$1"
  local max_lag="${2:-600}"
  local tip_slot expected

  tip_slot=$(extract_tip_slot "$log_file")
  expected=$(expected_current_slot)

  if (( tip_slot > 0 && tip_slot >= expected - max_lag )); then
    return 0
  fi
  return 1
}

# ── ImmutableDB helpers ─────────────────────────────────────────────────────

# count_immdb_blocks <immutable_dir>
#   Count blocks by summing secondary index file sizes / entry size.
count_immdb_blocks() {
  local immutable_dir="$1"
  local total=0
  for f in "$immutable_dir"/*.secondary; do
    [[ -f "$f" ]] || continue
    total=$(( total + $(stat -c%s "$f") / SECONDARY_INDEX_ENTRY_SIZE ))
  done
  echo "$total"
}

# count_immdb_chunks <immutable_dir>
count_immdb_chunks() {
  find "$1" -name '*.chunk' 2>/dev/null | wc -l
}

# ── S3 helpers (replacing MinIO mc) ─────────────────────────────────────────

# s3_count_chunks <bucket> <prefix> [region]
#   Count .chunk objects in the S3 bucket under prefix.
s3_count_chunks() {
  local bucket="$1" prefix="$2" region="${3:-$REGION}"
  aws s3api list-objects-v2 \
    --bucket "$bucket" --prefix "$prefix" \
    --query "length(Contents[?ends_with(Key, '.chunk')])" \
    --region "$region" --output text 2>/dev/null || echo "0"
}

# s3_highest_chunk <bucket> <prefix> [region]
#   Return the highest chunk number uploaded to S3.
s3_highest_chunk() {
  local bucket="$1" prefix="$2" region="${3:-$REGION}"
  aws s3api list-objects-v2 \
    --bucket "$bucket" --prefix "$prefix" \
    --query "Contents[?ends_with(Key, '.chunk')].Key" \
    --region "$region" --output text 2>/dev/null \
    | tr '\t' '\n' | grep '\.chunk$' | sed 's|.*/||; s/\.chunk$//' | sort | tail -1 \
    | sed 's/^0*//' || echo ""
}

# s3_object_exists <bucket> <key> [region]
s3_object_exists() {
  local bucket="$1" key="$2" region="${3:-$REGION}"
  aws s3api head-object --bucket "$bucket" --key "$key" --region "$region" \
    >/dev/null 2>&1
}

# s3_download <bucket> <key> <dest> [region]
s3_download() {
  local bucket="$1" key="$2" dest="$3" region="${4:-$REGION}"
  aws s3 cp "s3://${bucket}/${key}" "$dest" --region "$region" --quiet 2>/dev/null
}

# ── Progress logging ────────────────────────────────────────────────────────

# init_progress_csv <csv_file>
init_progress_csv() {
  echo "timestamp,elapsed_seconds,immdb_blocks,immdb_chunks,tip_slot,uploaded_chunks,phase" > "$1"
}

# log_progress <csv_file> <elapsed> <blocks> <chunks> <tip_slot> <uploaded> <phase>
log_progress() {
  local csv="$1" elapsed="$2" blocks="$3" chunks="$4" tip_slot="$5" uploaded="$6" phase="$7"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$elapsed,$blocks,$chunks,$tip_slot,$uploaded,$phase" >> "$csv"
}

# ── Uploader state helpers ──────────────────────────────────────────────────

# read_uploader_state <state_file>
#   Read the chunk-uploader state file; returns -1 if missing.
read_uploader_state() {
  local state_file="$1"
  if [[ -f "$state_file" ]]; then
    cat "$state_file" | tr -d '[:space:]'
  else
    echo "-1"
  fi
}

# ── Systemd helpers ─────────────────────────────────────────────────────────

# svc_is_active <unit>
svc_is_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

# svc_start_if_needed <unit>
svc_start_if_needed() {
  local unit="$1"
  if svc_is_active "$unit"; then
    echo "  $unit already running"
  else
    sudo systemctl start "$unit"
    echo "  Started $unit"
  fi
}

# svc_stop <unit>
svc_stop() {
  local unit="$1"
  if svc_is_active "$unit"; then
    sudo systemctl stop "$unit"
    echo "  Stopped $unit"
  fi
}

# svc_journal <unit> [lines]
#   Print recent journal lines for a unit.
svc_journal() {
  local unit="$1" lines="${2:-50}"
  sudo journalctl -u "$unit" --no-pager -n "$lines"
}
