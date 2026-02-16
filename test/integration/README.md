# Genesis Sync Accelerator: Integration Test

## Prerequisites

Running this test requires a few tools to be in PATH including:

- `cardano-node`
- `python3`

And of course `genesis-sync-accelerator`. The easiest way to get them is to enter
the `integration-test` nix shell. From the root of the repository:

```bash
nix develop .#integration-test
```

## Getting a valid chain to serve

Before running the actual test, you need to obtain a valid chain prefix to serve
from the CDN.

A way to do so is to use the `chain-init.sh` script in this directory. This script
syncs a cardano-node against the preprod testnet until at least 10 chunks are visible in the
`immutable` directory:

```bash
./chain-init.sh
```
The synced database is stored in `./test-data/source-db` and persists across
runs.

Both the database directory and required number of chunks are configurable:

```bash
DB_DIR=/tmp/my-chain MIN_CHUNKS=5 ./chain-init.sh
```

## Running the test

Once source data is available (the test will call `chain-init.sh` automatically if
needed), run the end-to-end test:

```bash
./run-test.sh
```

The test:

1. Ensures source ImmutableDB data exists (calls `chain-init.sh`)
2. Starts a local HTTP CDN serving the source immutable chunks
3. Starts the accelerator pointing at the CDN with an empty cache
4. Starts a consumer `cardano-node` that syncs only from the accelerator
5. Polls the consumer's ImmutableDB until all expected chunks appear (default timeout: 120s)
6. Validates each chunk/primary/secondary file against the source via `sha256sum`

### Configuration

These configuration parameters can be overridden via environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_DIR` | `./test-data/source-db` | Path to the source chain database |
| `SYNC_TIMEOUT` | `120` | Seconds to wait for the consumer to sync |

### Network Ports

The test uses the following ports:

| Service | Port |
|---------|------|
| CDN (python3 http.server) | 18080 |
| Accelerator | 13001 |
| Consumer cardano-node | 13100 |

### Cleanup

All background processes are cleaned up on exit. The source chain data is retained.
