#!/usr/bin/env bash
# Helpers for the CDN (chunk-uploader) integration test.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib.sh"

# ── MinIO helpers ────────────────────────────────────────────────────────────

# wait_for_minio <port> <timeout_seconds>
#   Block until MinIO's health endpoint responds.
wait_for_minio() {
  local port="$1" timeout="$2"
  local elapsed=0
  while ! curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      echo "${RED}MinIO did not become healthy within ${timeout}s${NC}"
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "  MinIO healthy on port $port"
}

# ── Component startup functions ──────────────────────────────────────────────

# start_minio <data_dir> <port> <console_port> <user> <password> <log_file>
start_minio() {
  local data_dir="$1" port="$2" console_port="$3" user="$4" password="$5" log_file="$6"
  MINIO_ROOT_USER="$user" \
  MINIO_ROOT_PASSWORD="$password" \
    setsid minio server "$data_dir" \
      --address ":${port}" \
      --console-address ":${console_port}" \
      >"$log_file" 2>&1 &
  echo $!
}

# start_chunk_uploader <immutable_dir> <bucket> <prefix> <endpoint> <region>
#                      <poll_interval> <state_file> <user> <password> <log_file>
start_chunk_uploader() {
  local immutable_dir="$1" bucket="$2" prefix="$3" endpoint="$4" region="$5"
  local poll_interval="$6" state_file="$7" user="$8" password="$9" log_file="${10}"
  AWS_ACCESS_KEY_ID="$user" \
  AWS_SECRET_ACCESS_KEY="$password" \
    setsid stdbuf -oL ${CHUNK_UPLOADER:-chunk-uploader} \
      --immutable-dir "$immutable_dir" \
      --s3-bucket "$bucket" \
      --s3-prefix "$prefix" \
      --s3-endpoint "$endpoint" \
      --s3-region "$region" \
      --poll-interval "$poll_interval" \
      --state-file "$state_file" \
      >"$log_file" 2>&1 &
  echo $!
}

# ── Setup ────────────────────────────────────────────────────────────────────

# setup_minio_bucket <port> <user> <password> <bucket> <mc_config_dir>
setup_minio_bucket() {
  local port="$1" user="$2" password="$3" bucket="$4" mc_config_dir="$5"
  MC_CONFIG_DIR="$mc_config_dir" \
    mc alias set local "http://127.0.0.1:${port}" "$user" "$password" --api S3v4 >/dev/null 2>&1
  MC_CONFIG_DIR="$mc_config_dir" \
    mc mb "local/$bucket" >/dev/null 2>&1
  echo "  Created bucket: $bucket"
}

# ── Count functions ──────────────────────────────────────────────────────────

# count_local_chunks <immutable_dir>
count_local_chunks() {
  find "$1" -name '*.chunk' 2>/dev/null | wc -l
}

# count_minio_chunks <bucket> <prefix> <mc_config_dir>
count_minio_chunks() {
  local bucket="$1" prefix="$2" mc_config_dir="$3"
  local count
  count=$(MC_CONFIG_DIR="$mc_config_dir" \
    mc ls "local/$bucket/$prefix" --recursive 2>/dev/null | grep -c '\.chunk' || true)
  echo "${count:-0}"
}

# ── Validation functions ─────────────────────────────────────────────────────

# check_upload_integrity <immutable_dir> <bucket> <prefix> <mc_config_dir> <download_dir>
check_upload_integrity() {
  local immutable_dir="$1" bucket="$2" prefix="$3" mc_config_dir="$4" download_dir="$5"
  local ok=true checked=0

  mkdir -p "$download_dir"

  local uploaded_chunks
  uploaded_chunks=$(MC_CONFIG_DIR="$mc_config_dir" \
    mc ls "local/$bucket/$prefix" --recursive 2>/dev/null \
    | grep '\.chunk$' | awk '{print $NF}' | sed 's/\.chunk$//' | sort)

  if [[ -z "$uploaded_chunks" ]]; then
    echo "  ${RED}FAIL${NC}: No chunks found in MinIO"
    return 1
  fi

  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    for ext in chunk primary secondary; do
      local local_file="$immutable_dir/${base}.${ext}"
      local remote_file="$download_dir/${base}.${ext}"

      if [[ ! -f "$local_file" ]]; then
        echo "  ${RED}UNEXPECTED${NC}: ${base}.${ext} in MinIO but not on local disk"
        ok=false
        continue
      fi

      if ! MC_CONFIG_DIR="$mc_config_dir" \
           mc cp "local/$bucket/${prefix}${base}.${ext}" "$remote_file" >/dev/null 2>&1; then
        echo "  ${RED}MISSING${NC}: ${base}.${ext} listed but could not download"
        ok=false
        continue
      fi

      local local_sum remote_sum
      local_sum=$(sha256sum "$local_file" | awk '{print $1}')
      remote_sum=$(sha256sum "$remote_file" | awk '{print $1}')
      if [[ "$local_sum" == "$remote_sum" ]]; then
        echo "  ${GREEN}OK${NC}: ${base}.${ext}"
      else
        echo "  ${RED}MISMATCH${NC}: ${base}.${ext}"
        ok=false
      fi
      checked=$((checked + 1))
    done
  done <<< "$uploaded_chunks"

  echo "  Checked $checked file(s)"

  if [[ "$ok" != "true" ]]; then
    echo "  ${RED}FAIL${NC}: Upload integrity check failed"
    return 1
  fi
  echo "  ${GREEN}All uploaded files match local${NC}"
  return 0
}

# check_tip_not_uploaded <immutable_dir> <bucket> <prefix> <mc_config_dir>
check_tip_not_uploaded() {
  local immutable_dir="$1" bucket="$2" prefix="$3" mc_config_dir="$4"
  local ok=true

  local tip_chunk
  tip_chunk=$(find "$immutable_dir" -name '*.chunk' -printf '%f\n' 2>/dev/null | sort | tail -1)
  local tip_base="${tip_chunk%.chunk}"

  if [[ -z "$tip_base" ]]; then
    echo "  ${RED}FAIL${NC}: No chunks found in $immutable_dir"
    return 1
  fi

  for ext in chunk primary secondary; do
    if MC_CONFIG_DIR="$mc_config_dir" \
       mc stat "local/$bucket/${prefix}${tip_base}.${ext}" >/dev/null 2>&1; then
      echo "  ${RED}UNEXPECTED${NC}: tip chunk ${tip_base}.${ext} was uploaded"
      ok=false
    fi
  done

  if [[ "$ok" != "true" ]]; then
    echo "  ${RED}FAIL${NC}: Tip chunk should not have been uploaded"
    return 1
  fi
  echo "  ${GREEN}OK${NC}: Tip chunk ${tip_base} correctly not uploaded"
  return 0
}

# check_state_file <state_file> <bucket> <prefix> <mc_config_dir>
check_state_file() {
  local state_file="$1" bucket="$2" prefix="$3" mc_config_dir="$4"

  if [[ ! -f "$state_file" ]]; then
    echo "  ${RED}FAIL${NC}: State file not found: $state_file"
    return 1
  fi

  local state_value
  state_value=$(cat "$state_file" | tr -d '[:space:]')

  local highest_uploaded
  highest_uploaded=$(MC_CONFIG_DIR="$mc_config_dir" \
    mc ls "local/$bucket/$prefix" --recursive 2>/dev/null \
    | grep '\.chunk$' | awk '{print $NF}' | sed 's/\.chunk$//' | sort | tail -1)
  local expected
  expected=$(echo "$highest_uploaded" | sed 's/^0*//')
  expected="${expected:-0}"

  if [[ "$state_value" == "$expected" ]]; then
    echo "  ${GREEN}OK${NC}: State file records last uploaded chunk as $state_value"
  else
    echo "  ${RED}FAIL${NC}: State file says '$state_value', expected '$expected'"
    return 1
  fi
  return 0
}

# check_uploads_increased <early_count> <final_count>
check_uploads_increased() {
  local early="$1" final="$2"
  if (( final > early )); then
    echo "  ${GREEN}OK${NC}: MinIO chunk count increased from $early to $final"
    return 0
  else
    echo "  ${RED}FAIL${NC}: MinIO chunk count did not increase (early=$early, final=$final)"
    return 1
  fi
}

# ── Demo mode helpers ────────────────────────────────────────────────────────

# demo_reexec_in_tmux — re-execute the calling script inside a tmux session.
demo_reexec_in_tmux() {
  [[ "${TMUX_DEMO_INNER:-}" == "1" ]] && return

  local session="cdn-demo-$$"
  local script="$0"
  local env_args=()
  for var in DEMO TMUX_DEMO_INNER MIN_CHUNKS TIMEOUT MINIO_PORT NODE_PORT \
             POLL_INTERVAL CHUNK_UPLOADER KEEP_WORKDIR; do
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

# demo_create_layout <node_log> <uploader_log> <minio_log>
demo_create_layout() {
  local node_log="$1" uploader_log="$2" minio_log="$3"

  tmux split-window -b -v -p 85 -t 0 "tail -f '$node_log'"
  tmux split-window -h -p 66 -t 0 "tail -f '$uploader_log'"
  tmux split-window -h -p 50 -t 1 "tail -f '$minio_log'"

  tmux select-pane -t 0 -T "NODE"
  tmux select-pane -t 1 -T "UPLOADER"
  tmux select-pane -t 2 -T "MINIO"
  tmux select-pane -t 3 -T "STATUS"

  tmux setw pane-border-status top
  tmux setw pane-border-format \
    '#[fg=white,bg=colour33,bold]  #{pane_title}  #[default]'
  tmux setw pane-border-style 'fg=colour33'
  tmux setw pane-active-border-style 'fg=colour33,bold'

  tmux select-pane -t 3
}

# demo_run_checks_in_panes <script_dir> <tmpdir> <immutable_dir> <bucket> <prefix>
#                          <mc_config_dir> <state_file> <early_count> <final_count>
demo_run_checks_in_panes() {
  local script_dir="$1" tmpdir="$2" immutable_dir="$3" bucket="$4" prefix="$5"
  local mc_config_dir="$6" state_file="$7" early_count="$8" final_count="$9"
  local rc_dir="$tmpdir/demo-rc"
  mkdir -p "$rc_dir"

  tmux respawn-pane -k -t 0 "bash -c '
    export MC_CONFIG_DIR=\"$mc_config_dir\"
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== Tip Exclusion ===${NC}\"
    echo \"\"
    check_tip_not_uploaded \"$immutable_dir\" \"$bucket\" \"$prefix\" \"$mc_config_dir\"
    echo \$? > \"$rc_dir/tip\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  tmux respawn-pane -k -t 1 "bash -c '
    export MC_CONFIG_DIR=\"$mc_config_dir\"
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== Integrity & State ===${NC}\"
    echo \"\"
    RC=0
    check_upload_integrity \"$immutable_dir\" \"$bucket\" \"$prefix\" \"$mc_config_dir\" \"$tmpdir/downloaded\" || RC=1
    echo \"\"
    check_state_file \"$state_file\" \"$bucket\" \"$prefix\" \"$mc_config_dir\" || RC=1
    echo \"\"
    check_uploads_increased \"$early_count\" \"$final_count\" || RC=1
    echo \$RC > \"$rc_dir/integrity\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  tmux respawn-pane -k -t 2 "bash -c '
    export MC_CONFIG_DIR=\"$mc_config_dir\"
    source \"$script_dir/lib.sh\"
    echo \"${BOLD}=== MinIO Bucket Contents ===${NC}\"
    echo \"\"
    MC_CONFIG_DIR=\"$mc_config_dir\" mc ls \"local/$bucket/$prefix\" --recursive 2>/dev/null || true
    echo \"\"
    TOTAL=\$(MC_CONFIG_DIR=\"$mc_config_dir\" mc ls \"local/$bucket/$prefix\" --recursive 2>/dev/null | wc -l)
    echo \"Total objects: \$TOTAL\"
    echo 0 > \"$rc_dir/listing\"
    echo \"\"
    echo \"Done. Waiting for other checks...\"
    sleep infinity
  '"

  local waited=0
  while (( waited < 120 )); do
    if [[ -f "$rc_dir/tip" && -f "$rc_dir/integrity" && -f "$rc_dir/listing" ]]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  local tip_rc integrity_rc
  tip_rc=$(cat "$rc_dir/tip" 2>/dev/null || echo "1")
  integrity_rc=$(cat "$rc_dir/integrity" 2>/dev/null || echo "1")

  if (( tip_rc == 0 && integrity_rc == 0 )); then
    echo ""
    echo "${GREEN}${BOLD}=== ALL CHECKS PASSED ===${NC}"
    return 0
  else
    echo ""
    echo "${RED}${BOLD}=== SOME CHECKS FAILED ===${NC}"
    [[ "$tip_rc" != "0" ]] && echo "  ${RED}Tip exclusion check failed${NC}"
    [[ "$integrity_rc" != "0" ]] && echo "  ${RED}Integrity/state checks failed${NC}"
    return 1
  fi
}
