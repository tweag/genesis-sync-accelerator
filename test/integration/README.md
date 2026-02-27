# Genesis Sync Accelerator: Integration Test

## Prerequisites

Running this test requires a few tools to be in PATH including:

- `cardano-node`
- `db-analyser` (from `ouroboros-consensus-cardano`)
- `python3`
- `curl`
- `jq`
- `ss`

And of course `genesis-sync-accelerator`. To satisfy these
requirements, you may enter the `integration-test` Nix shell.
First, [download Nix](https://nixos.org/download/) if you don't yet have it.
With Nix available, from the root of the repository:

```bash
nix develop .#integration-test
```

## Running the test

Run the end-to-end test:

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
| `MIN_CHUNKS` | `20` | Number of chunks (three files each) to serve from CDN (subset of source) |
| `GSA` | `genesis-sync-accelerator` | Path to the accelerator binary (useful for testing a cabal-built binary) |
| `CONSENSUS_MODE` | *(unset)* | Override consumer's ConsensusMode (e.g. `PraosMode` to bypass historicity check) |
| `CDN_PORT` | `3000` | Port for the local HTTP CDN |
| `ACCEL_PORT` | `3002` | Port for the accelerator |
| `CONSUMER_PORT` | `3001` | Port for the consumer cardano-node |
| `DEMO` | *(unset)* | If set to `1`, Start the test in an interactive demo mode (see below) |

### ConsensusMode

All nodes run in **GenesisMode**. The consumer connects to both the local
accelerator and real preprod peers, allowing it to validate the chain prefix
served by the accelerator against the real network.

### Cleanup

All background processes are cleaned up on exit. The source chain data is retained in `./test-data`.

## Demo mode

The integration test can optionally be run in a demo mode:

- Test phase transition is controlled by the user by manual key presses.
- Services output are shown side-by-side in a `tmux` session.

Test logic (service startup, validation) remains identical.
