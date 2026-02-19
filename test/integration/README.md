# Genesis Sync Accelerator: Integration Test

## Prerequisites

Running this test requires a few tools to be in PATH including:

- `cardano-node`
- `db-analyser` (from `ouroboros-consensus-cardano`)
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
4. Downloads the preprod peer snapshot for big ledger peer discovery
5. Starts a consumer `cardano-node` that syncs from the accelerator and real preprod peers
6. **Phase 1**: Waits for the consumer's ImmutableDB to accumulate enough chunk files
7. **Phase 2**: Stops the consumer, verifies block count via `db-analyser`
8. **Phase 3**: Validates accelerator participation — CDN downloads occurred, ChainSync messages served, blocks fetched from the accelerator via BlockFetch
9. **Phase 4**: Validates cache integrity — checks that whatever chunk files ARE cached match the CDN source byte-for-byte via `sha256sum`

### Configuration

These configuration parameters can be overridden via environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_DIR` | `./test-data/source-db` | Path to the source chain database |
| `CONSUMER_TIMEOUT` | `300` | Seconds to wait for the consumer's ImmutableDB to reach the target chunk count |
| `MIN_CHUNKS` | `20` | Number of chunk triplets to serve from CDN (subset of source) |
| `GSA` | `genesis-sync-accelerator` | Path to the accelerator binary (useful for testing a cabal-built binary) |
| `CONSENSUS_MODE` | *(unset)* | Override consumer's ConsensusMode (e.g. `PraosMode` to bypass historicity check) |

### Network Ports

The test uses the following ports:

| Service | Port |
|---------|------|
| CDN (python3 http.server) | 18080 |
| Accelerator | 13001 |
| Consumer cardano-node | 13100 |

### ConsensusMode

The consumer runs in **GenesisMode** (`consumer-config.json`) while chain-init
uses the default **PraosMode** (`config.json`). GenesisMode enables the Genesis
State Machine (GSM), ChainSync Jumping (CSJ), and the Genesis Density
Disconnector (GDD) — the features that the accelerator is designed to support.

GenesisMode requires a **peer snapshot file** for initial peer discovery — bootstrap
peers are a PraosMode mechanism (the official docs say "to revert to Praos mode,
use bootstrap peers from the topology file"). The test downloads the official
preprod `peer-snapshot.json` at runtime, which contains ~60 big ledger pool relay
addresses. These provide enough peers to satisfy the Honest Availability
Assumption (HAA) requirement of 5+ active big ledger peers.

The consumer connects to both the local accelerator (trusted local root) and
real preprod peers (discovered via the peer snapshot and ledger peer selection).
This allows GenesisMode to validate the chain prefix served by the accelerator
against the real network. GDD will eventually disconnect the accelerator once
real peers push the Limit on Eagerness forward — that's expected and fine since
the data has already been received.

chain-init uses PraosMode to sync from preprod via bootstrap peers in its
topology, since chain-init only needs to obtain raw chain data.

### PeerSharing

The consumer topology sets `useLedgerAfterSlot` to enter `Unrestricted`
association mode, allowing the consumer to discover additional peers via ledger
peer selection and peer sharing. The node auto-configures `PeerSharing` based on
forging status (since node 10.6.0).

### Cleanup

All background processes are cleaned up on exit. The source chain data is retained.
