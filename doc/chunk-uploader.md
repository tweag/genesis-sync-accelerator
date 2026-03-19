# Chunk Uploader

## What it is

The chunk uploader populates a CDN to use with the Genesis Sync Acceleartor. It watches a Cardano node's ImmutableDB directory for completed chunk files and uploads them to S3-compatible storage.

## Configuration

### CLI options

| Flag | Metavar | Default | Description |
|------|---------|---------|-------------|
| `--immutable-dir` | `PATH` | *(required)* | Path to the ImmutableDB `immutable/` directory to watch |
| `--s3-bucket` | `BUCKET` | *(required)* | S3 bucket name |
| `--s3-prefix` | `PREFIX` | `immutable/` | Key prefix for uploaded objects |
| `--s3-endpoint` | `URL` | *(optional)* | Custom S3 endpoint URL as `scheme://host[:port]` (for Cloudflare R2, MinIO, etc.) |
| `--s3-region` | `REGION` | `us-east-1` | AWS region |
| `--poll-interval` | `SECONDS` | `10` | How often to check for new chunks |
| `--state-file` | `PATH` | `<immutable-dir>/.chunk-uploader-state` | Upload progress state file |

### Environment variables

S3 credentials are provided through the standard AWS environment variables:

- `AWS_ACCESS_KEY_ID` — AWS access key
- `AWS_SECRET_ACCESS_KEY` — AWS secret key
