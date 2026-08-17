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
PROVIDERS_FILE="${GITHUB_WORKSPACE:-.}/config/cobalt_instances.json"
SOURCE_FILE="$WORK_DIR/cobalt-source"
AUDIO_FILE="$WORK_DIR/slopify.ogg"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

api_post() {
  local endpoint="$1"
  local payload="$2"

  curl --fail-with-body --silent --show-error \
    -X POST \
    -H "Authorization: Bearer $CALLBACK_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$CALLBACK_URL/internal/jobs/$JOB_ID/$endpoint"
}

status_update() {
  local state="$1"
  local message="$2"

  api_post status "$(
    jq -nc \
      --arg status "$state" \
      --arg message "$message" \
      '{status:$status,message:$message}'
  )" >/dev/null
}

fail_job() {
  local message="$1"
  echo "Slopify ingest failed: $message" >&2

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

if [[ ! -s "$PROVIDERS_FILE" ]]; then
  fail_job "Cobalt provider list is missing."
fi

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------
# We deliberately do NOT use yt-dlp for metadata anymore. YouTube's oEmbed
# endpoint is optional here; if it fails, we fall back to Cobalt's filename.
TITLE=""
ARTIST=""
UPLOADER=""
YOUTUBE_ID=""

status_update "extracting" "Reading media information..."

OEMBED="$(
  curl --silent --show-error --location \
    --connect-timeout 8 \
    --max-time 15 \
    --get \
    --data-urlencode "url=$YOUTUBE_URL" \
    --data-urlencode "format=json" \
    "https://www.youtube.com/oembed" \
    || true
)"

if jq -e . >/dev/null 2>&1 <<<"$OEMBED"; then
  TITLE="$(jq -r '.title // empty' <<<"$OEMBED")"
  ARTIST="$(jq -r '.author_name // empty' <<<"$OEMBED")"
  UPLOADER="$ARTIST"
fi

YOUTUBE_ID="$(
  python3 - "$YOUTUBE_URL" <<'PY'
import sys
from urllib.parse import urlparse, parse_qs

url = sys.argv[1]
u = urlparse(url)
host = u.netloc.lower().split(":")[0]

video_id = ""

if host in {"youtu.be", "www.youtu.be"}:
    video_id = u.path.strip("/").split("/")[0]
elif host.endswith("youtube.com"):
    if u.path == "/watch":
        video_id = parse_qs(u.query).get("v", [""])[0]
    elif u.path.startswith("/shorts/"):
        video_id = u.path.split("/")[2]
    elif u.path.startswith("/embed/"):
        video_id = u.path.split("/")[2]

print(video_id)
PY
)"

# ---------------------------------------------------------------------------
# Approved Cobalt failover pool
# ---------------------------------------------------------------------------

auth_for_provider() {
  local name="$1"

  case "$name" in
    Bergung) printf '%s' "${COBALT_BERGUNG_AUTH:-}" ;;
    Melon)   printf '%s' "${COBALT_MELON_AUTH:-}" ;;
    MGYTR)   printf '%s' "${COBALT_MGYTR_AUTH:-}" ;;
    *)       printf '' ;;
  esac
}

SUCCESS_PROVIDER=""
COBALT_FILENAME=""
LAST_ERROR=""

provider_count="$(jq '[.[] | select(.enabled == true)] | length' "$PROVIDERS_FILE")"

if [[ "$provider_count" -le 0 ]]; then
  fail_job "All community links down!"
fi

for index in $(seq 0 $((provider_count - 1))); do
  NAME="$(
    jq -r '[.[] | select(.enabled == true)]['"$index"'].name' \
      "$PROVIDERS_FILE"
  )"

  BASE="$(
    jq -r '[.[] | select(.enabled == true)]['"$index"'].url' \
      "$PROVIDERS_FILE"
  )"

  BASE="${BASE%/}"
  AUTH="$(auth_for_provider "$NAME")"

  echo
  echo "=================================================="
  echo "Trying Cobalt provider: $NAME"
  echo "API: $BASE"
  echo "=================================================="

  status_update \
    "working" \
    "Trying Cobalt provider $((index + 1))/$provider_count: $NAME..."

  REQUEST_JSON="$(
    jq -nc \
      --arg url "$YOUTUBE_URL" \
      '{
        url:$url,
        downloadMode:"audio",
        audioFormat:"ogg",
        audioBitrate:"128",
        filenameStyle:"pretty",
        disableMetadata:false,
        alwaysProxy:true,
        localProcessing:"disabled"
      }'
  )"

  RESPONSE_FILE="$WORK_DIR/cobalt-response-$index.json"
  HEADER_FILE="$WORK_DIR/cobalt-headers-$index.txt"

  CURL_ARGS=(
    --silent
    --show-error
    --location
    --connect-timeout 10
    --max-time 45
    -D "$HEADER_FILE"
    -o "$RESPONSE_FILE"
    -w "%{http_code}"
    -X POST
    -H "Accept: application/json"
    -H "Content-Type: application/json"
    --data "$REQUEST_JSON"
  )

  if [[ -n "$AUTH" ]]; then
    CURL_ARGS+=(-H "Authorization: $AUTH")
  fi

  set +e
  HTTP_CODE="$(
    curl "${CURL_ARGS[@]}" "$BASE/"
  )"
  CURL_EXIT=$?
  set -e

  if [[ "$CURL_EXIT" -ne 0 ]]; then
    LAST_ERROR="$NAME could not be reached (curl $CURL_EXIT)."
    echo "$LAST_ERROR"
    continue
  fi

  if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
    LAST_ERROR="$NAME returned HTTP $HTTP_CODE."
    echo "$LAST_ERROR"
    if [[ -s "$RESPONSE_FILE" ]]; then
      cat "$RESPONSE_FILE"
      echo
    fi
    continue
  fi

  if ! jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
    LAST_ERROR="$NAME returned invalid JSON."
    echo "$LAST_ERROR"
    continue
  fi

  STATUS="$(jq -r '.status // empty' "$RESPONSE_FILE")"
  DOWNLOAD_URL=""
  COBALT_FILENAME="$(jq -r '.filename // .output.filename // empty' "$RESPONSE_FILE")"

  case "$STATUS" in
    tunnel|redirect)
      DOWNLOAD_URL="$(jq -r '.url // empty' "$RESPONSE_FILE")"
      ;;

    local-processing)
      # For an audio-only request, the first tunnel is normally the source
      # audio. We still transcode the downloaded result to OGG below.
      DOWNLOAD_URL="$(jq -r '.tunnel[0] // empty' "$RESPONSE_FILE")"
      ;;

    picker)
      DOWNLOAD_URL="$(jq -r '.audio // empty' "$RESPONSE_FILE")"
      ;;

    error)
      ERROR_CODE="$(jq -r '.error.code // "unknown cobalt error"' "$RESPONSE_FILE")"
      LAST_ERROR="$NAME returned Cobalt error: $ERROR_CODE"
      echo "$LAST_ERROR"
      continue
      ;;

    *)
      LAST_ERROR="$NAME returned unsupported status: ${STATUS:-empty}"
      echo "$LAST_ERROR"
      continue
      ;;
  esac

  if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    LAST_ERROR="$NAME did not return a usable audio URL."
    echo "$LAST_ERROR"
    continue
  fi

  echo "Cobalt resolved media. Downloading through $NAME..."

  status_update \
    "downloading" \
    "$NAME resolved the song. Downloading audio..."

  rm -f "$SOURCE_FILE" "$AUDIO_FILE"

  set +e
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --connect-timeout 10 \
    --max-time 360 \
    -o "$SOURCE_FILE" \
    "$DOWNLOAD_URL"
  DOWNLOAD_EXIT=$?
  set -e

  if [[ "$DOWNLOAD_EXIT" -ne 0 || ! -s "$SOURCE_FILE" ]]; then
    LAST_ERROR="$NAME returned a media URL that could not be downloaded."
    echo "$LAST_ERROR"
    continue
  fi

  # Cobalt was asked for OGG, but normalize the output ourselves anyway.
  # This protects Slopify from instances returning another audio container.
  status_update "converting" "Preparing Slopify OGG audio..."

  set +e
  ffmpeg \
    -hide_banner \
    -loglevel error \
    -y \
    -i "$SOURCE_FILE" \
    -vn \
    -c:a libvorbis \
    -q:a 5 \
    "$AUDIO_FILE"
  FFMPEG_EXIT=$?
  set -e

  if [[ "$FFMPEG_EXIT" -ne 0 || ! -s "$AUDIO_FILE" ]]; then
    LAST_ERROR="$NAME audio could not be converted."
    echo "$LAST_ERROR"
    continue
  fi

  SUCCESS_PROVIDER="$NAME"
  break
done

if [[ -z "$SUCCESS_PROVIDER" ]]; then
  echo "Last provider error: ${LAST_ERROR:-unknown}"
  fail_job "All community links down!"
fi

echo "Cobalt provider succeeded: $SUCCESS_PROVIDER"

# If oEmbed did not return a title, use Cobalt's filename.
if [[ -z "$TITLE" ]]; then
  TITLE="${COBALT_FILENAME:-Untitled}"
  TITLE="${TITLE%.*}"
fi

if [[ -z "$ARTIST" ]]; then
  ARTIST="Unknown Artist"
fi

if [[ -z "$UPLOADER" ]]; then
  UPLOADER="$ARTIST"
fi

# Duration is read from the finished OGG instead of from YouTube.
DURATION="$(
  ffprobe \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$AUDIO_FILE" \
    | awk '{printf "%d\n", $1}'
)"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  DURATION=0
fi

# ---------------------------------------------------------------------------
# Return completed media to the existing Cloudflare/R2 bridge
# ---------------------------------------------------------------------------

status_update "uploading" "Uploading finished audio to Cloudflare R2..."

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
    --arg provider "$SUCCESS_PROVIDER" \
    --argjson duration "$DURATION" \
    '{
      youtube_id:$youtube_id,
      source_url:$source_url,
      title:$title,
      artist:$artist,
      uploader:$uploader,
      genre:$genre,
      duration:$duration,
      cobalt_provider:$provider
    }'
)"

api_post complete "$COMPLETE_JSON"

echo
echo "Slopify ingest complete:"
echo "  Title:    $TITLE"
echo "  Artist:   $ARTIST"
echo "  Duration: ${DURATION}s"
echo "  Provider: $SUCCESS_PROVIDER"
