#!/usr/bin/env bash
# Shared helpers for all integration tests.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Port / process helpers ───────────────────────────────────────────────────

# wait_for_port <port> <timeout_seconds> [label]
#   Block until something is listening on <port>, or fail.
wait_for_port() {
  local port="$1" timeout="$2" label="${3:-service}"
  local elapsed=0
  while ! ss -tlnp 2>/dev/null | grep -q ":${port} "; do
    if (( elapsed >= timeout )); then
      echo "${RED}$label did not start on port $port within ${timeout}s${NC}"
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "  $label listening on port $port"
}

# ── Component startup functions ──────────────────────────────────────────────

# start_cardano_node <config> <db_path> <topology> <port> <socket> <log_file>
start_cardano_node() {
  local config="$1" db_path="$2" topology="$3" port="$4" socket="$5" log_file="$6"
  setsid stdbuf -oL cardano-node run \
    --config "$config" \
    --database-path "$db_path" \
    --topology "$topology" \
    --port "$port" \
    --socket-path "$socket" \
    >"$log_file" 2>&1 &
  echo $!
}

# ── Demo mode helpers ────────────────────────────────────────────────────────

# demo_is_active — returns 0 if DEMO=1
demo_is_active() {
  [[ "${DEMO:-}" == "1" ]]
}

# demo_require_tmux — check tmux is installed
demo_require_tmux() {
  if ! command -v tmux &>/dev/null; then
    echo "${RED}DEMO=1 requires tmux but it is not installed.${NC}"
    exit 1
  fi
}

# demo_prompt <message> — print message and wait for Enter (demo mode only)
demo_prompt() {
  local message="$1"
  echo ""
  read -rp "  $message"
}
