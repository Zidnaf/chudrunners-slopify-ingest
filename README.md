# ChudRunners Slopify GitHub Runner

This repository exists only to provide a temporary Linux runner for yt-dlp and
ffmpeg.

## Required repository secret

Create:

`SLOPIFY_CALLBACK_TOKEN`

It must exactly match the Cloudflare Worker secret:

`CALLBACK_TOKEN`

No R2 credentials are stored in GitHub.

## Required files

Keep these on the repository's default branch:

- `.github/workflows/slopify-ingest.yml`
- `scripts/slopify_ingest.sh`

The Worker triggers this workflow with GitHub's `repository_dispatch` event.
