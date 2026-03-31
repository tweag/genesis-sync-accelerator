# Chunk Uploader

A background service that monitors a Cardano node's ImmutableDB directory for completed chunks and uploads them to S3-compatible storage (AWS S3, Cloudflare R2, MinIO, etc.). It is the companion to the Genesis Sync Accelerator, populating the CDN that the accelerator serves from.

## Usage

```
chunk-uploader --immutable-dir PATH --s3-bucket BUCKET [OPTIONS]
```

AWS credentials are read from the standard environment variables / credential chain.

### Options

| Option | Default | Description |
|---|---|---|
| `--immutable-dir PATH` | *(required)* | ImmutableDB `immutable/` directory to watch |
| `--s3-bucket BUCKET` | *(required)* | S3 bucket name |
| `--s3-prefix PREFIX` | `immutable/` | Key prefix for uploaded objects |
| `--s3-endpoint URL` | *(none)* | Custom S3 endpoint (`scheme://host[:port]`) for R2, MinIO, etc. |
| `--s3-region REGION` | `us-east-1` | AWS region |
| `--poll-interval SECONDS` | `10` | How often to check for new chunks |
| `--state-file PATH` | `<immutable-dir>/.chunk-uploader-state` | Upload progress state file |
| `--config PATH` | *(none)* | Cardano node config file; enables automatic `tip.json` upload |

## How it works

1. Polls the immutable directory for completed chunks. A chunk is considered complete when the *next* chunk's `.chunk` file exists, confirming the current one is finalized.
2. Uploads each completed chunk's three files (`.chunk`, `.primary`, `.secondary`) to the configured S3 bucket.
3. Records the last successfully uploaded chunk number in a state file so it can resume without re-uploading.
4. Retries failed uploads with exponential backoff.
5. When `--config` is provided, generates and uploads `tip.json` to `<prefix>tip.json` after each batch of new chunks, reflecting the current ImmutableDB tip (slot, block number, and hash).

## License

Copyright 2026 Modus Create, LLC.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
