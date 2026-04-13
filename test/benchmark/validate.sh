#!/usr/bin/env bash
#
# Validate chunk-uploader correctness after Phase 1.
#
# Checks:
#   1. Count:      local chunks - 1 (tip) == S3 chunks
#   2. Integrity:  sample of chunks match SHA-256 between local and S3
#   3. Tip excl.:  highest local chunk is NOT in S3
#   4. State file: value matches highest S3 chunk
#   5. tip.json:   present in S3 with valid fields
#   6. Contiguity: chunks 0..N with no gaps
#
# Usage:
#   BUCKET=<bucket-name> bash test/benchmark/validate.sh
#
# Environment:
#   BUCKET           (required) S3 bucket name
#   AWS_REGION       Region (default: us-east-1)
#   DATA_DIR         Data root (default: /data)
#   SAMPLE_SIZE      Number of chunks to integrity-check (default: 20)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

BUCKET="${BUCKET:?BUCKET env var is required}"
DATA_DIR="${DATA_DIR:-/data}"
REGION="${AWS_REGION:-us-east-1}"
SAMPLE_SIZE="${SAMPLE_SIZE:-20}"

IMMUTABLE_DIR="$DATA_DIR/phase1/node-db/immutable"
UPLOADER_STATE="$DATA_DIR/phase1/state/uploader-state"

TMPDIR="$(mktemp -d -t gsa-validate.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "${BOLD}=== Chunk-Uploader Validation ===${NC}"
echo "  Bucket:       $BUCKET"
echo "  Immutable:    $IMMUTABLE_DIR"
echo "  Sample size:  $SAMPLE_SIZE"
echo ""

VALIDATION_RC=0

# ── Check 1: Count ──────────────────────────────────────────────────────────

echo "${BOLD}--- Check 1: Chunk count ---${NC}"

LOCAL_CHUNKS=$(count_immdb_chunks "$IMMUTABLE_DIR")
LOCAL_EXPECTED=$(( LOCAL_CHUNKS - 1 ))  # tip excluded
S3_CHUNKS=$(s3_count_chunks "$BUCKET" "immutable/" "$REGION")

# Handle "None" or empty from aws cli.
[[ "$S3_CHUNKS" == "None" || -z "$S3_CHUNKS" ]] && S3_CHUNKS=0

echo "  Local chunks:    $LOCAL_CHUNKS (expecting $LOCAL_EXPECTED uploaded)"
echo "  S3 chunks:       $S3_CHUNKS"

if (( S3_CHUNKS == LOCAL_EXPECTED )); then
  echo "  ${GREEN}PASS${NC}: Counts match"
elif (( S3_CHUNKS >= LOCAL_EXPECTED - 1 && S3_CHUNKS <= LOCAL_EXPECTED )); then
  # Allow off-by-one: the node may have created a new chunk between stopping
  # the uploader and running validation.
  echo "  ${GREEN}PASS${NC}: Counts within tolerance ($S3_CHUNKS vs $LOCAL_EXPECTED)"
else
  echo "  ${RED}FAIL${NC}: Count mismatch"
  VALIDATION_RC=1
fi

# ── Check 2: Integrity (sample) ─────────────────────────────────────────────

echo ""
echo "${BOLD}--- Check 2: Integrity (sampling $SAMPLE_SIZE chunks) ---${NC}"

# List all S3 chunk numbers.
S3_CHUNK_LIST="$TMPDIR/s3-chunks.txt"
aws s3api list-objects-v2 \
  --bucket "$BUCKET" --prefix "immutable/" \
  --query "Contents[?ends_with(Key, '.chunk')].Key" \
  --region "$REGION" --output text 2>/dev/null \
  | tr '\t' '\n' | grep '\.chunk$' | sed 's|.*/||; s/\.chunk$//' | sort \
  > "$S3_CHUNK_LIST"

TOTAL_S3=$(wc -l < "$S3_CHUNK_LIST")

if (( TOTAL_S3 == 0 )); then
  echo "  ${RED}FAIL${NC}: No chunks found in S3"
  VALIDATION_RC=1
else
  # Pick a sample: evenly spaced + first + last.
  SAMPLE_FILE="$TMPDIR/sample.txt"
  if (( TOTAL_S3 <= SAMPLE_SIZE )); then
    cp "$S3_CHUNK_LIST" "$SAMPLE_FILE"
  else
    # First, last, and evenly spaced in between.
    head -1 "$S3_CHUNK_LIST" > "$SAMPLE_FILE"
    tail -1 "$S3_CHUNK_LIST" >> "$SAMPLE_FILE"
    STEP=$(( TOTAL_S3 / (SAMPLE_SIZE - 2) ))
    awk -v step="$STEP" 'NR % step == 0' "$S3_CHUNK_LIST" >> "$SAMPLE_FILE"
    sort -u "$SAMPLE_FILE" > "$SAMPLE_FILE.tmp" && mv "$SAMPLE_FILE.tmp" "$SAMPLE_FILE"
  fi

  CHECKED=0
  INTEGRITY_OK=true
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    for ext in chunk primary secondary; do
      local_file="$IMMUTABLE_DIR/${base}.${ext}"
      remote_file="$TMPDIR/${base}.${ext}"

      if [[ ! -f "$local_file" ]]; then
        echo "  ${RED}UNEXPECTED${NC}: ${base}.${ext} in S3 but not on local disk"
        INTEGRITY_OK=false
        continue
      fi

      if ! s3_download "$BUCKET" "immutable/${base}.${ext}" "$remote_file" "$REGION"; then
        echo "  ${RED}MISSING${NC}: ${base}.${ext} listed but could not download"
        INTEGRITY_OK=false
        continue
      fi

      local_sum=$(sha256sum "$local_file" | awk '{print $1}')
      remote_sum=$(sha256sum "$remote_file" | awk '{print $1}')
      if [[ "$local_sum" == "$remote_sum" ]]; then
        echo "  ${GREEN}OK${NC}: ${base}.${ext}"
      else
        echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
        INTEGRITY_OK=false
      fi
      CHECKED=$((CHECKED + 1))
      rm -f "$remote_file"
    done
  done < "$SAMPLE_FILE"

  echo "  Checked $CHECKED file(s)"
  if [[ "$INTEGRITY_OK" != "true" ]]; then
    echo "  ${RED}FAIL${NC}: Integrity check failed"
    VALIDATION_RC=1
  else
    echo "  ${GREEN}PASS${NC}: All sampled files match"
  fi
fi

# ── Check 3: Tip exclusion ──────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Check 3: Tip exclusion ---${NC}"

TIP_CHUNK=$(find "$IMMUTABLE_DIR" -name '*.chunk' -printf '%f\n' 2>/dev/null | sort | tail -1)
TIP_BASE="${TIP_CHUNK%.chunk}"

if [[ -z "$TIP_BASE" ]]; then
  echo "  ${RED}FAIL${NC}: No chunks found in $IMMUTABLE_DIR"
  VALIDATION_RC=1
else
  TIP_OK=true
  for ext in chunk primary secondary; do
    if s3_object_exists "$BUCKET" "immutable/${TIP_BASE}.${ext}" "$REGION"; then
      echo "  ${RED}UNEXPECTED${NC}: tip chunk ${TIP_BASE}.${ext} was uploaded"
      TIP_OK=false
    fi
  done

  if [[ "$TIP_OK" == "true" ]]; then
    echo "  ${GREEN}PASS${NC}: Tip chunk ${TIP_BASE} correctly not uploaded"
  else
    echo "  ${RED}FAIL${NC}: Tip chunk should not have been uploaded"
    VALIDATION_RC=1
  fi
fi

# ── Check 4: State file ─────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Check 4: State file ---${NC}"

if [[ ! -f "$UPLOADER_STATE" ]]; then
  echo "  ${RED}FAIL${NC}: State file not found: $UPLOADER_STATE"
  VALIDATION_RC=1
else
  STATE_VALUE=$(cat "$UPLOADER_STATE" | tr -d '[:space:]')
  S3_HIGHEST=$(s3_highest_chunk "$BUCKET" "immutable/" "$REGION")
  S3_HIGHEST="${S3_HIGHEST:-0}"

  if [[ "$STATE_VALUE" == "$S3_HIGHEST" ]]; then
    echo "  ${GREEN}PASS${NC}: State file records last uploaded chunk as $STATE_VALUE"
  else
    echo "  ${RED}FAIL${NC}: State file says '$STATE_VALUE', expected '$S3_HIGHEST'"
    VALIDATION_RC=1
  fi
fi

# ── Check 5: tip.json ───────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Check 5: tip.json ---${NC}"

TIP_JSON="$TMPDIR/tip.json"
if s3_download "$BUCKET" "immutable/tip.json" "$TIP_JSON" "$REGION"; then
  # Verify required fields.
  TIP_OK=true
  for field in slot block_no hash; do
    if ! grep -q "\"$field\"" "$TIP_JSON"; then
      echo "  ${RED}MISSING FIELD${NC}: $field"
      TIP_OK=false
    fi
  done

  if [[ "$TIP_OK" == "true" ]]; then
    TIP_SLOT=$(grep -oP '"slot"\s*:\s*\K[0-9]+' "$TIP_JSON" || echo "0")
    TIP_BLOCK=$(grep -oP '"block_no"\s*:\s*\K[0-9]+' "$TIP_JSON" || echo "0")
    echo "  tip.json: slot=$TIP_SLOT block_no=$TIP_BLOCK"
    if (( TIP_SLOT > 0 && TIP_BLOCK > 0 )); then
      echo "  ${GREEN}PASS${NC}: tip.json is valid"
    else
      echo "  ${RED}FAIL${NC}: tip.json has zero values"
      VALIDATION_RC=1
    fi
  else
    echo "  ${RED}FAIL${NC}: tip.json is missing required fields"
    VALIDATION_RC=1
  fi
else
  echo "  ${RED}FAIL${NC}: tip.json not found in S3"
  VALIDATION_RC=1
fi

# ── Check 6: Contiguity ─────────────────────────────────────────────────────

echo ""
echo "${BOLD}--- Check 6: Contiguity ---${NC}"

if (( TOTAL_S3 > 0 )); then
  # Check that chunk numbers form a contiguous range 00000..N.
  EXPECTED_HIGHEST=$(tail -1 "$S3_CHUNK_LIST" | sed 's/^0*//')
  EXPECTED_HIGHEST="${EXPECTED_HIGHEST:-0}"
  EXPECTED_COUNT=$(( EXPECTED_HIGHEST + 1 ))

  if (( TOTAL_S3 == EXPECTED_COUNT )); then
    echo "  ${GREEN}PASS${NC}: Chunks 0..$EXPECTED_HIGHEST are contiguous ($TOTAL_S3 chunks)"
  else
    echo "  ${RED}FAIL${NC}: Expected $EXPECTED_COUNT chunks (0..$EXPECTED_HIGHEST) but found $TOTAL_S3"
    # Find gaps.
    echo "  Looking for gaps..."
    seq -w 0 "$EXPECTED_HIGHEST" | while read -r n; do
      padded=$(printf "%05d" "$((10#$n))")
      if ! grep -q "^${padded}$" "$S3_CHUNK_LIST"; then
        echo "    Missing: $padded"
      fi
    done | head -20
    VALIDATION_RC=1
  fi
else
  echo "  ${RED}SKIP${NC}: No chunks to check"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if (( VALIDATION_RC == 0 )); then
  echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
else
  echo "${RED}${BOLD}=== SOME CHECKS FAILED ===${NC}"
fi

exit "$VALIDATION_RC"
