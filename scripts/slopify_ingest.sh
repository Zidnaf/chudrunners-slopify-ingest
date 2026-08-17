#!/usr/bin/env bash
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

require JOB_ID
require YOUTUBE_URL
require GENRE
require CALLBACK_URL
require CALLBACK_TOKEN

WORK_DIR="$(mktemp -d)"
META="$WORK_DIR/meta.json"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

api_post() {
  local endpoint="$1"
  local json="$2"

  curl --fail-with-body --silent --show-error \
    -X POST \
    -H "Authorization: Bearer $CALLBACK_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$json" \
    "$CALLBACK_URL/internal/jobs/$JOB_ID/$endpoint"
}

fail_job() {
  local message="$1"
  echo "Slopify ingest failed: $message" >&2

  # Best effort callback. Do not mask the original failure if this also fails.
  curl --silent --show-error \
    -X POST \
    -H "Authorization: Bearer $CALLBACK_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg e "$message" '{error:$e}')" \
    "$CALLBACK_URL/internal/jobs/$JOB_ID/failed" \
    >/dev/null || true

  exit 1
}

trap 'fail_job "GitHub runner failed while processing this song."' ERR

api_post status '{"status":"extracting","message":"Reading YouTube metadata..."}'

yt-dlp \
  --no-playlist \
  --extractor-args "youtube:player_client=mweb" \
  --skip-download \
  --dump-single-json \
  "$YOUTUBE_URL" \
  > "$META"

YOUTUBE_ID="$(jq -r '.id // empty' "$META")"
TITLE="$(jq -r '.title // "Untitled"' "$META")"
UPLOADER="$(jq -r '.uploader // ""' "$META")"
ARTIST="$(jq -r '.artist // .creator // .uploader // "Unknown Artist"' "$META")"
DURATION="$(jq -r '.duration // 0 | floor' "$META")"

if [[ -z "$YOUTUBE_ID" ]]; then
  fail_job "YouTube metadata did not contain a video ID."
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  fail_job "YouTube duration was invalid."
fi

if (( DURATION <= 0 )); then
  fail_job "YouTube duration could not be determined."
fi

if (( DURATION > ${MAX_DURATION:-900} )); then
  fail_job "Video is too long (${DURATION}s). Maximum is ${MAX_DURATION:-900}s."
fi

api_post status '{"status":"downloading","message":"Downloading YouTube audio..."}'

yt-dlp \
  --no-playlist \
  --extractor-args "youtube:player_client=mweb" \
  -f "bestaudio/best" \
  -x \
  --audio-format vorbis \
  --audio-quality 5 \
  -o "$WORK_DIR/%(id)s.%(ext)s" \
  "$YOUTUBE_URL"

AUDIO_FILE="$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.ogg' -print -quit)"

if [[ -z "$AUDIO_FILE" || ! -s "$AUDIO_FILE" ]]; then
  fail_job "yt-dlp/ffmpeg did not produce a usable OGG file."
fi

api_post status '{"status":"uploading","message":"Uploading finished audio to Cloudflare R2..."}'

curl --fail-with-body --silent --show-error \
  -X PUT \
  -H "Authorization: Bearer $CALLBACK_TOKEN" \
  -H "Content-Type: audio/ogg" \
  --data-binary "@$AUDIO_FILE" \
  "$CALLBACK_URL/internal/jobs/$JOB_ID/audio"

COMPLETE_JSON="$(
  jq -nc \
    --arg youtube_id "$YOUTUBE_ID" \
    --arg source_url "$YOUTUBE_URL" \
    --arg title "$TITLE" \
    --arg artist "$ARTIST" \
    --arg uploader "$UPLOADER" \
    --arg genre "$GENRE" \
    --argjson duration "$DURATION" \
    '{
      youtube_id:$youtube_id,
      source_url:$source_url,
      title:$title,
      artist:$artist,
      uploader:$uploader,
      genre:$genre,
      duration:$duration
    }'
)"

api_post complete "$COMPLETE_JSON"

echo "Slopify ingest complete: $TITLE"
