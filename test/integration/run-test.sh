#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REQUIRED_TOOLS=(cardano-node genesis-sync-accelerator db-analyser python3)

for cmd in "${REQUIRED_TOOLS[@]}"; do
  path=$(command -v "$cmd" || true)
  if [ -z "$path" ]; then
    path="not found"
  fi
  printf "  %-30s\t%s\n" "${BOLD}${cmd}${NC}" "$path"
done

