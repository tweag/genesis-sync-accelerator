#!/usr/bin/env bash
# Helpers for the GSA (genesis-sync-accelerator) integration test.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"

# ── Component startup functions ──────────────────────────────────────────────

# start_cdn <data_dir> <port> <log_file>
start_cdn() {
  local data_dir="$1" port="$2" log_file="$3"
  python3 -m http.server "$port" --directory "$data_dir" \
    >"$log_file" 2>&1 &
  echo $!
}

# start_accelerator <cache_dir> <config> <cdn_url> <port> <max_chunks> <log_file>
start_accelerator() {
  local cache_dir="$1" config="$2" cdn_url="$3" port="$4" max_chunks="$5" log_file="$6"
  stdbuf -oL ${GSA:-genesis-sync-accelerator} \
    --config "$config" \
    --rs-src-url "$cdn_url" \
    --cache-dir "$cache_dir" \
    --port "$port" \
    --max-cached-chunks "$max_chunks" \
    +RTS -T -RTS \
    >"$log_file" 2>&1 &
  echo $!
}

# start_consumer — alias for start_cardano_node (from shared lib)
start_consumer() {
  start_cardano_node "$@"
}

# ── Validation functions ─────────────────────────────────────────────────────

# check_block_count <consumer_db> <config> <expected>
check_block_count() {
  local consumer_db="$1" config="$2" expected="$3"
  local out block_count
  out=$(db-analyser --db "$consumer_db" --config "$config" --count-blocks --v1-in-mem 2>&1) || true
  block_count=$(echo "$out" | grep -oP 'Counted \K[0-9]+' || echo "")

  if [[ -z "$block_count" ]]; then
    echo "  ${RED}FAIL${NC}: db-analyser did not report a block count"
    echo "--- db-analyser output ---"
    echo "$out"
    return 1
  fi

  echo "  Consumer ImmutableDB: ${block_count} blocks (expected >= ${expected})"

  if (( block_count >= expected )); then
    echo "  ${GREEN}OK${NC}: ${block_count} blocks in ImmutableDB (>= ${expected})"
    return 0
  else
    echo "  ${RED}FAIL${NC}: Only ${block_count} blocks in ImmutableDB (need >= ${expected})"
    echo "--- db-analyser output ---"
    echo "$out"
    return 1
  fi
}

# check_blockfetch_served <accel_log>
check_blockfetch_served() {
  local accel_log="$1"
  local served
  served=$(grep -c 'TraceBlockFetchServerSendBlock' "$accel_log" 2>/dev/null) || true
  echo "  Accelerator served ${served} block(s) via BlockFetch"
  if (( served > 0 )); then
    echo "  ${GREEN}OK${NC}: Accelerator served blocks"
    return 0
  else
    echo "  ${RED}FAIL${NC}: Accelerator served no blocks"
    return 1
  fi
}

# check_cdn_downloads <cdn_log>
check_cdn_downloads() {
  local cdn_log="$1"
  local count
  count=$(grep -c '"GET .* HTTP/.*" 200' "$cdn_log" 2>/dev/null) || true
  echo "  CDN HTTP 200 responses: ${count}"
  if (( count > 0 )); then
    echo "  ${GREEN}OK${NC}: Accelerator downloaded data from CDN"
    return 0
  else
    echo "  ${RED}FAIL${NC}: No CDN downloads detected"
    return 1
  fi
}

# check_chainsync_messages <accel_log>
check_chainsync_messages() {
  local accel_log="$1"
  local count
  count=$(grep -cE 'MsgRollForward|MsgIntersectFound' "$accel_log" 2>/dev/null) || true
  echo "  Accelerator ChainSync messages: ${count}"
  if (( count > 0 )); then
    echo "  ${GREEN}OK${NC}: Accelerator served ChainSync data"
    return 0
  else
    echo "  ${RED}FAIL${NC}: No ChainSync interaction detected in accelerator log"
    return 1
  fi
}

# check_blockfetch_from_accel <node_log>
check_blockfetch_from_accel() {
  local node_log="$1"
  local count
  count=$(grep -c 'CompletedBlockFetch.*127\.0\.0\.1' "$node_log" 2>/dev/null) || true
  echo "  BlockFetch completions from accelerator (127.0.0.1): ${count}"
  if (( count > 0 )); then
    echo "  ${GREEN}OK${NC}: Blocks were fetched from the accelerator"
    return 0
  else
    echo "  ${RED}FAIL${NC}: No BlockFetch completions from accelerator detected"
    echo "  (Requires TraceBlockFetchClient: true in consumer config)"
    return 1
  fi
}

# check_cache_integrity <cache_dir> <source_dir>
check_cache_integrity() {
  local cache_dir="$1" source_dir="$2"
  local cached_chunks checked=0 ok=true

  cached_chunks=$(find "$cache_dir" -maxdepth 1 -name '*.chunk' 2>/dev/null | wc -l)
  echo "  Accelerator cache has ${cached_chunks} chunk(s)"

  for cached_chunk in "$cache_dir"/*.chunk; do
    [[ -f "$cached_chunk" ]] || continue
    local base
    base="$(basename "$cached_chunk" .chunk)"
    for ext in chunk primary secondary; do
      local cached_file="$cache_dir/${base}.${ext}"
      local src_file="$source_dir/${base}.${ext}"
      [[ -f "$cached_file" ]] || continue
      if [[ ! -f "$src_file" ]]; then
        echo "  ${RED}UNEXPECTED${NC}: ${base}.${ext} in cache but not in CDN source"
        ok=false
        continue
      fi
      local src_sum cache_sum
      src_sum=$(sha256sum "$src_file" | awk '{print $1}')
      cache_sum=$(sha256sum "$cached_file" | awk '{print $1}')
      if [[ "$src_sum" == "$cache_sum" ]]; then
        echo "  ${GREEN}OK${NC}: ${base}.${ext}"
      else
        echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
        ok=false
      fi
      checked=$((checked + 1))
    done
  done

  echo "  Checked ${checked} file(s)"

  if [[ "$ok" != "true" ]]; then
    echo "  ${RED}FAIL${NC}: Cache integrity check failed"
    return 1
  fi
  if (( checked == 0 )); then
    echo "  ${RED}FAIL${NC}: No cached files to verify"
    return 1
  fi
  return 0
}

# check_consumer_integrity <consumer_db> <source_dir>
check_consumer_integrity() {
  local consumer_db="$1" source_dir="$2"
  local ok=true checked=0

  local last_chunk last_base=""
  last_chunk=$(ls "$consumer_db/immutable"/*.chunk 2>/dev/null | sort | tail -1)
  if [[ -n "$last_chunk" ]]; then
    last_base="$(basename "$last_chunk" .chunk)"
  fi

  echo "  Consumer ImmutableDB vs source:"
  for src_chunk in "$source_dir"/*.chunk; do
    [[ -f "$src_chunk" ]] || continue
    local base
    base="$(basename "$src_chunk" .chunk)"
    # Skip the consumer's tip chunk — it may have been extended beyond the source.
    [[ "$base" == "$last_base" ]] && continue
    for ext in chunk primary secondary; do
      local consumer_file="$consumer_db/immutable/${base}.${ext}"
      local src_file="$source_dir/${base}.${ext}"
      [[ -f "$consumer_file" ]] || continue
      local src_sum consumer_sum
      src_sum=$(sha256sum "$src_file" | awk '{print $1}')
      consumer_sum=$(sha256sum "$consumer_file" | awk '{print $1}')
      if [[ "$src_sum" == "$consumer_sum" ]]; then
        echo "  ${GREEN}OK${NC}: ${base}.${ext}"
      else
        echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
        ok=false
      fi
      checked=$((checked + 1))
    done
  done

  echo "  Checked ${checked} consumer file(s)"

  if [[ "$ok" != "true" ]]; then
    echo "  ${RED}FAIL${NC}: Consumer integrity check failed"
    return 1
  fi
  return 0
}

# ── Demo mode helpers ────────────────────────────────────────────────────────

# demo_reexec_in_tmux — re-execute the calling script inside a tmux session.
demo_reexec_in_tmux() {
  [[ "${TMUX_DEMO_INNER:-}" == "1" ]] && return

  local session="gsa-demo-$$"
  local script="$0"
  local env_args=()
  for var in DEMO TMUX_DEMO_INNER DB_DIR MIN_CHUNKS GSA CONSENSUS_MODE CONSUMER_TIMEOUT; do
    if [[ -n "${!var:-}" ]]; then
      env_args+=("$var=${!var}")
    fi
  done
  env_args+=("TMUX_DEMO_INNER=1")

  tmux new-session -d -s "$session" -x "$(tput cols)" -y "$(tput lines)" \
    "env ${env_args[*]} bash $script"
  tmux set-option -t "$session" -g mouse on
  tmux set-option -t "$session" -g history-limit 50000
  tmux attach-session -t "$session"
  exit 0
}

# demo_create_layout <cdn_log> <accel_log> <node_log>
demo_create_layout() {
  local cdn_log="$1" accel_log="$2" node_log="$3"

  tmux split-window -b -v -p 85 -t 0 "tail -f '$cdn_log'"
  tmux split-window -h -p 66 -t 0 "tail -f '$accel_log'"
  tmux split-window -h -p 50 -t 1 "tail -f '$node_log'"

  tmux select-pane -t 0 -T "CDN"
  tmux select-pane -t 1 -T "ACCELERATOR"
  tmux select-pane -t 2 -T "CONSUMER"
  tmux select-pane -t 3 -T "STATUS"

  tmux setw pane-border-status top
  tmux setw pane-border-format \
    '#[fg=white,bg=colour33,bold]  #{pane_title}  #[default]'
  tmux setw pane-border-style 'fg=colour33'
  tmux setw pane-active-border-style 'fg=colour33,bold'

  tmux select-pane -t 3
}

# demo_run_checks_in_panes <tmpdir> <accel_cache> <cdn_data> <consumer_db> <config> <expected_immutable>
demo_run_checks_in_panes() {
  local tmpdir="$1" accel_cache="$2" cdn_data="$3" consumer_db="$4" config="$5" expected="$6"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local rc_dir="$tmpdir/demo-rc"
  mkdir -p "$rc_dir"

  tmux respawn-pane -k -t 0 "bash -c '
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== CDN Checks ===${NC}\"
    echo \"\"
    check_cdn_downloads \"$tmpdir/cdn.log\"
    echo \$? > \"$rc_dir/cdn\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  tmux respawn-pane -k -t 1 "bash -c '
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== Accelerator Checks ===${NC}\"
    echo \"\"
    RC=0
    check_chainsync_messages \"$tmpdir/accelerator.log\" || RC=1
    echo \"\"
    check_blockfetch_served \"$tmpdir/accelerator.log\" || RC=1
    echo \"\"
    check_cache_integrity \"$accel_cache\" \"$cdn_data\" || RC=1
    echo \$RC > \"$rc_dir/accel\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  tmux respawn-pane -k -t 2 "bash -c '
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== Consumer Checks ===${NC}\"
    echo \"\"
    RC=0
    check_block_count \"$consumer_db\" \"$config\" \"$expected\" || RC=1
    echo \"\"
    check_blockfetch_from_accel \"$tmpdir/node.log\" || RC=1
    echo \"\"
    check_consumer_integrity \"$consumer_db\" \"$cdn_data\" || RC=1
    echo \$RC > \"$rc_dir/consumer\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  local waited=0
  while (( waited < 120 )); do
    if [[ -f "$rc_dir/cdn" && -f "$rc_dir/accel" && -f "$rc_dir/consumer" ]]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  local cdn_rc accel_rc consumer_rc
  cdn_rc=$(cat "$rc_dir/cdn" 2>/dev/null || echo "1")
  accel_rc=$(cat "$rc_dir/accel" 2>/dev/null || echo "1")
  consumer_rc=$(cat "$rc_dir/consumer" 2>/dev/null || echo "1")

  if (( cdn_rc == 0 && accel_rc == 0 && consumer_rc == 0 )); then
    echo ""
    echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
    return 0
  else
    echo ""
    echo "${RED}${BOLD}=== SOME CHECKS FAILED ===${NC}"
    [[ "$cdn_rc" != "0" ]] && echo "  ${RED}CDN checks failed${NC}"
    [[ "$accel_rc" != "0" ]] && echo "  ${RED}Accelerator checks failed${NC}"
    [[ "$consumer_rc" != "0" ]] && echo "  ${RED}Consumer checks failed${NC}"
    return 1
  fi
}
