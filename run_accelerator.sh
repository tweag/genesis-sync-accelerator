#!/usr/bin/env bash
# Clear and setup cache directory
rm -rf test-data/accelerator-cache
mkdir -p test-data/accelerator-cache

echo "Starting Genesis Sync Accelerator on port 3001..."
cabal run genesis-sync-accelerator -- \
  +RTS -T -RTS \
  --db test-data/accelerator-cache \
  --config ouroboros-consensus-cardano/test/tools-test/disk/config/config.json \
  --rs-src-url http://localhost:8080 \
  --rs-cache-url test-data/accelerator-cache \
  --port 3001 \
  --max-cached-chunks 2
