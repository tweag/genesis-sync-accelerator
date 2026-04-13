#!/usr/bin/env bash
#
# On-instance setup for the GSA benchmark.
#
# Run this on the EC2 instance after launch. It installs Nix, builds the
# project, fetches mainnet configuration, formats/mounts the data volume,
# and installs systemd service units.
#
# Usage:
#   BUCKET=gsa-benchmark-mainnet-YYYYMMDD bash test/benchmark/setup-instance.sh
#
# Prerequisites:
#   - EC2 instance with IAM instance profile (from provision.sh)
#   - 500 GB gp3 EBS volume attached (detected automatically)
#   - Internet access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DATA_DIR="/data"
CONFIG_DIR="$DATA_DIR/config"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="${BUCKET:?BUCKET env var is required (e.g. gsa-benchmark-mainnet-20260413)}"

# Mainnet config base URL.
MAINNET_CONFIG_URL="https://book.play.dev.cardano.org/environments/mainnet"

echo "=== GSA Benchmark: Instance Setup ==="
echo "  Repo:    $REPO_ROOT"
echo "  Data:    $DATA_DIR"
echo "  Bucket:  $BUCKET"
echo "  Region:  $REGION"
echo ""

# ── Step 1: Data volume ─────────────────────────────────────────────────────

echo "--- Step 1: Data volume ---"

if mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo "  $DATA_DIR is already mounted"
else
  # Find the data volume. Common device names for the second EBS volume:
  # /dev/xvdf, /dev/nvme1n1, /dev/sdf (symlinked).
  DATA_DEV=""
  for dev in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    if [[ -b "$dev" ]]; then
      DATA_DEV="$dev"
      break
    fi
  done

  if [[ -z "$DATA_DEV" ]]; then
    echo "  ERROR: No data volume found. Attach a second EBS volume and retry."
    echo "  Looked for: /dev/nvme1n1, /dev/xvdf, /dev/sdf"
    exit 1
  fi

  echo "  Found data volume: $DATA_DEV"

  # Format only if no filesystem exists.
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    echo "  Formatting $DATA_DEV as ext4..."
    sudo mkfs.ext4 -L gsa-data "$DATA_DEV"
  else
    echo "  $DATA_DEV already has a filesystem"
  fi

  sudo mkdir -p "$DATA_DIR"
  sudo mount "$DATA_DEV" "$DATA_DIR"

  # Persist across reboots.
  if ! grep -q "$DATA_DEV" /etc/fstab; then
    echo "$DATA_DEV $DATA_DIR ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
    echo "  Added $DATA_DEV to /etc/fstab"
  fi

  sudo chown "$(id -u):$(id -g)" "$DATA_DIR"
  echo "  Mounted $DATA_DEV at $DATA_DIR"
fi

# ── Step 2: Directory structure ──────────────────────────────────────────────

echo ""
echo "--- Step 2: Directory structure ---"

for d in \
  "$CONFIG_DIR" \
  "$DATA_DIR/phase1/node-db" \
  "$DATA_DIR/phase1/state" \
  "$DATA_DIR/phase2/node-db" \
  "$DATA_DIR/phase2/gsa-cache"; do
  mkdir -p "$d"
done
echo "  Created $DATA_DIR/{config,phase1,phase2} hierarchy"

# ── Step 3: Install Nix ─────────────────────────────────────────────────────

echo ""
echo "--- Step 3: Nix ---"

if command -v nix >/dev/null 2>&1; then
  echo "  Nix already installed"
else
  echo "  Installing Nix (single-user)..."
  curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
  # Source nix profile for the rest of this script.
  # shellcheck disable=SC1091
  . "$HOME/.nix-profile/etc/profile.d/nix.sh" 2>/dev/null \
    || . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" 2>/dev/null \
    || true
  echo "  Nix installed"
fi

# ── Step 4: Build project ───────────────────────────────────────────────────

echo ""
echo "--- Step 4: Build ---"

cd "$REPO_ROOT"

echo "  Building GSA and chunk-uploader (this may take a while on first run)..."
echo "  Using the integration-test devShell which includes cardano-node."
echo ""
echo "  Tip: to enter the shell interactively, run:"
echo "    cd $REPO_ROOT && nix develop .#integration-test"
echo ""

# Build the key executables. nix build caches results.
nix build .#genesis-sync-accelerator --no-link 2>&1 | tail -5
nix build .#chunk-uploader --no-link 2>&1 | tail -5

# Verify the integration-test shell has cardano-node.
echo "  Verifying integration-test shell provides cardano-node..."
nix develop .#integration-test --command which cardano-node >/dev/null 2>&1 \
  && echo "  OK: cardano-node available in integration-test shell" \
  || echo "  WARNING: cardano-node not found — you may need to build it separately"

# ── Step 5: Fetch mainnet configuration ──────────────────────────────────────

echo ""
echo "--- Step 5: Mainnet configuration ---"

MAINNET_FILES=(
  config.json
  byron-genesis.json
  shelley-genesis.json
  alonzo-genesis.json
  conway-genesis.json
  topology.json
)

for f in "${MAINNET_FILES[@]}"; do
  if [[ -f "$CONFIG_DIR/$f" ]]; then
    echo "  $f already present"
  else
    echo "  Downloading $f..."
    curl -sSfL "$MAINNET_CONFIG_URL/$f" -o "$CONFIG_DIR/$f"
  fi
done

# Peer snapshot.
if [[ -f "$CONFIG_DIR/peer-snapshot.json" ]]; then
  echo "  peer-snapshot.json already present"
else
  echo "  Downloading peer-snapshot.json..."
  curl -sSfL "$MAINNET_CONFIG_URL/peer-snapshot.json" -o "$CONFIG_DIR/peer-snapshot.json"
fi

# ── Step 6: Patch config.json ────────────────────────────────────────────────

echo ""
echo "--- Step 6: Patch config.json ---"

CONFIG_FILE="$CONFIG_DIR/config.json"
PATCHED=false

# Ensure GenesisMode.
if ! grep -q '"GenesisMode"' "$CONFIG_FILE"; then
  # If ConsensusMode is present, replace it; otherwise add it.
  if grep -q '"ConsensusMode"' "$CONFIG_FILE"; then
    sed -i 's/"ConsensusMode":\s*"[^"]*"/"ConsensusMode": "GenesisMode"/' "$CONFIG_FILE"
  else
    # Insert after the opening brace.
    sed -i '1a\  "ConsensusMode": "GenesisMode",' "$CONFIG_FILE"
  fi
  PATCHED=true
  echo "  Set ConsensusMode to GenesisMode"
else
  echo "  ConsensusMode already GenesisMode"
fi

# Ensure P2P is enabled.
if grep -q '"EnableP2P":\s*false' "$CONFIG_FILE"; then
  sed -i 's/"EnableP2P":\s*false/"EnableP2P": true/' "$CONFIG_FILE"
  PATCHED=true
  echo "  Enabled P2P"
fi

# Ensure useful trace flags for timing and monitoring.
for flag in TraceChainDb TraceBlockFetchClient TraceConnectionManager TracePeerSelection; do
  if grep -q "\"$flag\":\s*false" "$CONFIG_FILE"; then
    sed -i "s/\"$flag\":\s*false/\"$flag\": true/" "$CONFIG_FILE"
    PATCHED=true
    echo "  Enabled $flag"
  fi
done

if [[ "$PATCHED" == "false" ]]; then
  echo "  No patches needed"
fi

# ── Step 7: Install systemd units ────────────────────────────────────────────

echo ""
echo "--- Step 7: Systemd units ---"

SYSTEMD_SRC="$SCRIPT_DIR/systemd"
SYSTEMD_DST="/etc/systemd/system"

if [[ -d "$SYSTEMD_SRC" ]]; then
  for unit in "$SYSTEMD_SRC"/*.service; do
    [[ -f "$unit" ]] || continue
    unit_name="$(basename "$unit")"
    sudo cp "$unit" "$SYSTEMD_DST/$unit_name"
    echo "  Installed $unit_name"
  done
  sudo systemctl daemon-reload
  echo "  Reloaded systemd"
else
  echo "  No systemd units found in $SYSTEMD_SRC"
fi

# ── Step 8: Write environment file ──────────────────────────────────────────

echo ""
echo "--- Step 8: Environment file ---"

ENV_FILE="$DATA_DIR/benchmark.env"
cat > "$ENV_FILE" <<EOF
# GSA benchmark environment — sourced by systemd units and run scripts.
BUCKET=$BUCKET
AWS_REGION=$REGION
DATA_DIR=$DATA_DIR
CONFIG_DIR=$CONFIG_DIR
REPO_ROOT=$REPO_ROOT
GSA_COMMIT=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
INSTANCE_TYPE=$(curl -sf http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown")
EOF

echo "  Written $ENV_FILE"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Enter the dev shell:  cd $REPO_ROOT && nix develop .#integration-test"
echo "  2. Run Phase 1:          bash test/benchmark/run-phase1.sh"
echo "  3. Validate uploader:    bash test/benchmark/validate.sh"
echo "  4. Run Phase 2:          bash test/benchmark/run-phase2.sh"
echo "  5. Collect results:      bash test/benchmark/report.sh"
