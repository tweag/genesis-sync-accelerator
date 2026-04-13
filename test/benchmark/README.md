# GSA Mainnet Sync Benchmark

Measures real sync times: **baseline** (normal Cardano P2P network) vs. **GSA-accelerated** (serving from S3).

## Overview

| Phase | What runs | What it measures |
|-------|-----------|------------------|
| **Phase 1** | cardano-node (mainnet) + chunk-uploader → S3 | Baseline sync time; validates chunk-uploader in a real scenario |
| **Phase 2** | GSA (reading from S3) + fresh cardano-node | GSA-accelerated sync time |

## AWS Infrastructure

| Resource | Spec | Notes |
|----------|------|-------|
| EC2 | `r6i.2xlarge` (8 vCPU, 64 GB RAM) | Good single-thread perf + enough RAM for ledger state |
| EBS (data) | 500 GB gp3, 6000 IOPS, 400 MB/s | Persistent across reboots |
| S3 | Same-region bucket | 30-day auto-expiry |

Estimated cost: **~$25–$50** for a full run (both phases).

## Quick Start

### 1. Provision AWS resources (from your machine)

```bash
# Requires: AWS CLI with IAM/S3 permissions
bash test/benchmark/provision.sh gsa-benchmark-mainnet-20260413
```

### 2. Launch EC2 instance

Launch an `r6i.2xlarge` in the same region with:
- Instance profile: `gsa-benchmark-profile`
- 500 GB gp3 EBS attached as secondary volume
- Security group: outbound all, inbound SSH only

### 3. Setup the instance (via SSH)

```bash
git clone <repo-url> gsa && cd gsa
BUCKET=gsa-benchmark-mainnet-20260413 bash test/benchmark/setup-instance.sh
```

### 4. Run Phase 1: Baseline sync + chunk upload

```bash
cd gsa && nix develop .#integration-test
BUCKET=gsa-benchmark-mainnet-20260413 bash test/benchmark/run-phase1.sh
```

This will take **24–72 hours**. The script is idempotent — you can safely re-run it after interruption and it will resume monitoring.

Progress is logged to `/data/phase1/progress.csv` (one row per minute).

### 5. Validate chunk-uploader

```bash
BUCKET=gsa-benchmark-mainnet-20260413 bash test/benchmark/validate.sh
```

Checks: count, integrity (SHA-256 sample), tip exclusion, state file, tip.json, contiguity.

### 6. Run Phase 2: GSA-accelerated sync

```bash
BUCKET=gsa-benchmark-mainnet-20260413 bash test/benchmark/run-phase2.sh
```

### 7. Collect results

```bash
BUCKET=gsa-benchmark-mainnet-20260413 bash test/benchmark/report.sh
```

### 8. Teardown

```bash
bash test/benchmark/teardown.sh gsa-benchmark-mainnet-20260413
# Also: terminate the EC2 instance and delete EBS volumes via the console.
```

## Crash Recovery

All services auto-restart on failure:

| Component | Recovery |
|-----------|----------|
| **cardano-node** | Resumes from on-disk ledger snapshots + ImmutableDB (~2 min penalty) |
| **chunk-uploader** | Resumes from state file; re-scans and uploads only new chunks |
| **GSA** | Stateless — restarts instantly, cache is just an optimization |

In foreground mode (default), `run-phase1.sh` will also auto-restart the chunk-uploader if it dies.

## Systemd Mode

Set `USE_SYSTEMD=1` to manage services via systemd instead of foreground processes. This is more robust for multi-day runs (survives SSH disconnection) but requires `setup-instance.sh` to have installed the unit files.

```bash
USE_SYSTEMD=1 BUCKET=... bash test/benchmark/run-phase1.sh
```

The monitoring loop still runs in the foreground; use `tmux` or `screen` for SSH resilience.

## Configuration

All scripts accept configuration via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUCKET` | *(required)* | S3 bucket name |
| `AWS_REGION` | `us-east-1` | AWS region |
| `DATA_DIR` | `/data` | Data volume mount point |
| `NODE_PORT` | `3000` / `3002` | cardano-node port (Phase 1 / Phase 2) |
| `GSA_PORT` | `3001` | GSA listening port |
| `MAX_CACHED_CHUNKS` | `20` | GSA cache size |
| `PREFETCH_AHEAD` | `10` | GSA prefetch window |
| `POLL_INTERVAL` | `60` | Monitoring interval (seconds) |
| `MAX_SYNC_TIME` | `259200` | Timeout (seconds, default 72h) |
| `USE_SYSTEMD` | `0` | Set to `1` for systemd mode |
| `SAMPLE_SIZE` | `20` | Chunks to integrity-check in validate.sh |

## File Layout

```
test/benchmark/
├── README.md              ← you are here
├── lib.sh                 # Shared helpers
├── provision.sh           # Create S3 + IAM (run locally)
├── setup-instance.sh      # On-instance: Nix, build, config, EBS
├── run-phase1.sh          # Baseline sync + chunk-uploader
├── run-phase2.sh          # GSA-accelerated sync
├── validate.sh            # Chunk-uploader correctness checks
├── report.sh              # Collect timing results
├── teardown.sh            # AWS resource cleanup
└── systemd/
    ├── cardano-node@.service
    ├── chunk-uploader.service
    └── gsa.service
```

Data on the instance:

```
/data/
├── benchmark.env          # Written by setup-instance.sh
├── config/                # Mainnet config files
├── phase1/
│   ├── node-db/           # Baseline node ChainDB
│   ├── node.log
│   ├── uploader.log
│   ├── state/uploader-state
│   ├── start-time / end-time
│   └── progress.csv
└── phase2/
    ├── node-db/           # GSA consumer ChainDB
    ├── gsa-cache/
    ├── gsa.log
    ├── node.log
    ├── gsa-topology.json
    ├── start-time / end-time
    └── progress.csv
```
