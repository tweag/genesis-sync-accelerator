# Genesis Sync Accelerator: Integration Test

## Prerequesites

Running this test requires a few tools to be in PATH including:

- `cardano-node`
- `db-analyser`
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
syncs a cardano-node against the prepod testnet until at least 10 chunks are visible in the
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

TODO Dummy for now

```bash
./run-test.sh
```
