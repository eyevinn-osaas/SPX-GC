#!/bin/sh

# Generate config.json with PORT from environment variable
cat > /app/config.json << EOF
{
  "general": {
    "username": "${SPX_USERNAME:-admin}",
    "password": "${SPX_PASSWORD:-}",
    "hostname": "${OSC_HOSTNAME:-}",
    "greeting": "",
    "langfile": "english.json",
    "loglevel": "${SPX_LOGLEVEL:-info}",
    "launchBrowser": false,
    "apikey": "${SPX_APIKEY:-}",
    "logfolder": "/app/log/",
    "dataroot": "/data",
    "templatesource": "spx-ip-address",
    "port": ${PORT:-5656},
    "disableConfigUI": false,
    "disableLocalRenderer": false,
    "disableOpenFolderCommand": true,
    "disableSeveralControllersWarning": false,
    "hideRendererCursor": false,
    "resolution": "HD",
    "preview": "selected",
    "renderer": "normal",
    "autoplayLocalRenderer": true,
    "recents": []
  },
  "casparcg": {
    "servers": []
  },
  "osc": {
    "enable": false,
    "port": 57121
  },
  "globalExtras": {
    "customscript": "/ExtraFunctions/demoFunctions.js",
    "CustomControls": []
  }
}
EOF

# Optional endpoint for MinIO or other S3-compatible storage
ENDPOINT_ARG=""
if [ -n "$S3_ENDPOINT_URL" ]; then
  ENDPOINT_ARG="--endpoint-url $S3_ENDPOINT_URL"
  echo "Using custom S3 endpoint: $S3_ENDPOINT_URL"
fi

SYNC_INTERVAL="${S3_SYNC_INTERVAL:-60}"

# Control which side is the source of truth for deletions.
# When "true", S3/MinIO is the source of truth: only MinIO deletions propagate, SPX deletions are undone.
# When "false" (default), SPX is the source of truth: only SPX deletions propagate, MinIO deletions are undone.
# Adding/editing files always works from both sides regardless of this setting.
S3_SOURCE_OF_TRUTH="${S3_SOURCE_OF_TRUTH:-false}"
if [ "$S3_SOURCE_OF_TRUTH" = "true" ]; then
  UPLOAD_DELETE=""
  DOWNLOAD_DELETE="--delete"
  echo "S3_SOURCE_OF_TRUTH is enabled. S3/MinIO is the source of truth for deletions."
else
  UPLOAD_DELETE="--delete"
  DOWNLOAD_DELETE=""
  echo "SPX is the source of truth for deletions (default)."
fi

# Initial S3 project download before anything else, so that persistent
# data (like the host ID file) is available before SPX starts.
if [ -n "$S3_PROJECTS_URL" ]; then
  mkdir -p /data
  echo "Performing initial S3 project download from $S3_PROJECTS_URL..."
  aws s3 sync "$S3_PROJECTS_URL" /data $ENDPOINT_ARG 2>&1 | while read line; do
    echo "[S3 Projects Initial Download] $line"
  done
fi

# Persist a stable host ID across container restarts.
# Without this, SPX derives its Host-ID from the container MAC address,
# which changes on every suspend/resume and breaks license-based plugins.
HOST_ID_FILE="/data/.spx-host-id"
mkdir -p /data
if [ -f "$HOST_ID_FILE" ]; then
  export SPX_HOST_ID=$(cat "$HOST_ID_FILE")
  echo "Loaded persistent SPX Host-ID: $SPX_HOST_ID"
else
  SPX_HOST_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-8)
  echo "$SPX_HOST_ID" > "$HOST_ID_FILE"
  export SPX_HOST_ID
  echo "Generated new persistent SPX Host-ID: $SPX_HOST_ID"
fi

# Start background S3 sync for templates if S3_TEMPLATES_URL is set
if [ -n "$S3_TEMPLATES_URL" ]; then
  TEMPLATES_SYNC_TARGET="/app/ASSETS/templates"

  mkdir -p "$TEMPLATES_SYNC_TARGET"

  echo "Starting bidirectional S3 template sync with $S3_TEMPLATES_URL (local: $TEMPLATES_SYNC_TARGET, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      # Upload local changes to S3 first (so new files are safe before download runs)
      aws s3 sync "$TEMPLATES_SYNC_TARGET" "$S3_TEMPLATES_URL" $UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Templates Upload] $line"
      done
      # Then download from S3
      aws s3 sync "$S3_TEMPLATES_URL" "$TEMPLATES_SYNC_TARGET" $DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Templates Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for projects if S3_PROJECTS_URL is set
if [ -n "$S3_PROJECTS_URL" ]; then
  PROJECTS_SYNC_TARGET="/data"

  mkdir -p "$PROJECTS_SYNC_TARGET"

  echo "Starting bidirectional S3 project sync with $S3_PROJECTS_URL (local: $PROJECTS_SYNC_TARGET, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      # Upload local changes to S3 first (so new files are safe before download runs)
      aws s3 sync "$PROJECTS_SYNC_TARGET" "$S3_PROJECTS_URL" $UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Projects Upload] $line"
      done
      # Then download from S3
      aws s3 sync "$S3_PROJECTS_URL" "$PROJECTS_SYNC_TARGET" $DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Projects Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for plugins if S3_PLUGINS_URL is set
if [ -n "$S3_PLUGINS_URL" ]; then
  PLUGINS_SYNC_TARGET="/app/ASSETS/plugins"

  mkdir -p "$PLUGINS_SYNC_TARGET"

  echo "Starting bidirectional S3 plugin sync with $S3_PLUGINS_URL (local: $PLUGINS_SYNC_TARGET, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      # Upload local changes to S3 first (so new files are safe before download runs)
      aws s3 sync "$PLUGINS_SYNC_TARGET" "$S3_PLUGINS_URL" $UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Plugins Upload] $line"
      done
      # Then download from S3
      aws s3 sync "$S3_PLUGINS_URL" "$PLUGINS_SYNC_TARGET" $DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Plugins Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for media if S3_MEDIA_URL is set
if [ -n "$S3_MEDIA_URL" ]; then
  MEDIA_SYNC_TARGET="/app/ASSETS/media"

  mkdir -p "$MEDIA_SYNC_TARGET"

  echo "Starting bidirectional S3 media sync with $S3_MEDIA_URL (local: $MEDIA_SYNC_TARGET, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      # Upload local changes to S3 first (so new files are safe before download runs)
      aws s3 sync "$MEDIA_SYNC_TARGET" "$S3_MEDIA_URL" $UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Media Upload] $line"
      done
      # Then download from S3
      aws s3 sync "$S3_MEDIA_URL" "$MEDIA_SYNC_TARGET" $DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Media Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

exec node server.js
