# GSA Sync Benchmark

Measures real sync times: **baseline** (normal Cardano P2P network) vs. **GSA-accelerated** (serving from S3).

Works on both **mainnet** (full benchmark, 24–72h) and **preprod** (smoke test, 1–4h).

## Overview

| Phase | What runs | What it measures |
|-------|-----------|------------------|
| **Phase 1** | cardano-node + chunk-uploader → S3 | Baseline sync time; validates chunk-uploader in a real scenario |
| **Phase 2** | GSA (reading from S3) + fresh cardano-node | GSA-accelerated sync time |

## AWS Infrastructure

Provisioned via Terraform (`terraform/` directory).

| Resource | Mainnet | Preprod |
|----------|---------|---------|
| EC2 | `r6i.2xlarge` (64 GB RAM) | `r6i.large` (16 GB RAM) |
| EBS (data) | 500 GB gp3 | 50 GB gp3 |
| S3 | Same-region bucket, 30-day expiry | Same |
| **Cost** | **~$25–$50** | **~$1–$3** |

## Quick Start (Terraform)

### Prerequisites

- Terraform >= 1.5
- AWS credentials configured (`aws configure` or env vars)
- An existing EC2 key pair in the target region

### 1. Provision everything

```bash
cd test/benchmark/terraform

terraform init

# Mainnet (full benchmark):
terraform apply \
  -var ssh_key_name=my-key \
  -var ssh_cidr="$(curl -s ifconfig.me)/32"

# Or preprod (quick smoke test):
terraform apply \
  -var ssh_key_name=my-key \
  -var ssh_cidr="$(curl -s ifconfig.me)/32" \
  -var network=preprod \
  -var instance_type=r6i.large \
  -var volume_size_gb=50
```

This creates the S3 bucket, IAM role, security group, EC2 instance, and
EBS volume. Cloud-init automatically sets up the instance (Nix, repo
clone, Cardano config download, directory structure).

### 2. SSH in and wait for cloud-init

```bash
# Terraform prints the SSH command in its output.
ssh -i my-key.pem ec2-user@<public-ip>

# Wait for setup to finish:
while [ ! -f /data/.cloud-init-done ]; do sleep 5; echo "waiting..."; done
```

### 3. Build (first time only)

```bash
cd gsa && nix develop .#integration-test
# This enters a shell with cardano-node, chunk-uploader, GSA, etc.
```

### 4. Run Phase 1: Baseline sync + chunk upload

```bash
# BUCKET is in /data/benchmark.env, written by cloud-init.
source /data/benchmark.env
BUCKET=$BUCKET bash test/benchmark/run-phase1.sh
```

Mainnet: **24–72 hours**. Preprod: **1–4 hours**. The script is idempotent — safe to re-run after interruption.

Progress is logged to `/data/phase1/progress.csv` (one row per minute).

### 5. Validate chunk-uploader

```bash
BUCKET=$BUCKET bash test/benchmark/validate.sh
```

Checks: count, integrity (SHA-256 sample), tip exclusion, state file, tip.json, contiguity.

### 6. Run Phase 2: GSA-accelerated sync

```bash
BUCKET=$BUCKET bash test/benchmark/run-phase2.sh
```

### 7. Collect results

```bash
BUCKET=$BUCKET bash test/benchmark/report.sh
```

### 8. Teardown

```bash
# From your local machine:
cd test/benchmark/terraform
terraform destroy
```

This removes everything: instance, EBS volume, S3 bucket (including contents), IAM role.

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
├── provision.sh           # Create S3 + IAM (legacy, use terraform instead)
├── setup-instance.sh      # On-instance setup (cloud-init runs this automatically)
├── run-phase1.sh          # Baseline sync + chunk-uploader
├── run-phase2.sh          # GSA-accelerated sync
├── validate.sh            # Chunk-uploader correctness checks
├── report.sh              # Collect timing results
├── teardown.sh            # AWS cleanup (legacy, use terraform destroy instead)
├── systemd/
│   ├── cardano-node@.service
│   ├── chunk-uploader.service
│   └── gsa.service
└── terraform/
    ├── main.tf            # Provider, AMI lookup, locals
    ├── variables.tf       # All inputs (instance type, network, SSH key, etc.)
    ├── s3.tf              # Bucket + lifecycle + public access block
    ├── iam.tf             # Role, policy, instance profile
    ├── network.tf         # Security group (default VPC)
    ├── ec2.tf             # Instance + EBS volume + cloud-init
    ├── cloud-init.yaml    # Instance bootstrap template
    └── outputs.tf         # IP, bucket name, SSH command, next steps
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
