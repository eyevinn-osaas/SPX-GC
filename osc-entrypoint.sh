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

# Control which side is the source of truth for deletions, per resource type.
# "s3"  = S3/MinIO is the source of truth: only MinIO deletions propagate, SPX deletions are undone.
# "spx" = SPX is the source of truth: only SPX deletions propagate, MinIO deletions are undone.
# Adding/editing files always works from both sides regardless of this setting.
PROJECTS_SOT="${S3_PROJECTS_SOURCE_OF_TRUTH:-spx}"
TEMPLATES_SOT="${S3_TEMPLATES_SOURCE_OF_TRUTH:-s3}"
PLUGINS_SOT="${S3_PLUGINS_SOURCE_OF_TRUTH:-s3}"
MEDIA_SOT="${S3_MEDIA_SOURCE_OF_TRUTH:-s3}"

# Helper: set UPLOAD_DELETE and DOWNLOAD_DELETE based on source of truth value
set_sync_flags() {
  if [ "$1" = "spx" ]; then
    UPLOAD_DELETE="--delete"
    DOWNLOAD_DELETE=""
  else
    UPLOAD_DELETE=""
    DOWNLOAD_DELETE="--delete"
  fi
}

echo "Source of truth: projects=$PROJECTS_SOT, templates=$TEMPLATES_SOT, plugins=$PLUGINS_SOT, media=$MEDIA_SOT"

# Initial S3 download for ALL types before anything else.
# This ensures local directories are populated before sync loops start,
# preventing the first upload cycle from wiping S3 content with --delete.
if [ -n "$S3_PROJECTS_URL" ]; then
  mkdir -p /data
  echo "Performing initial S3 project download from $S3_PROJECTS_URL..."
  aws s3 sync "$S3_PROJECTS_URL" /data $ENDPOINT_ARG 2>&1 | while read line; do
    echo "[S3 Projects Initial Download] $line"
  done
fi

if [ -n "$S3_TEMPLATES_URL" ]; then
  mkdir -p /app/ASSETS/templates
  echo "Performing initial S3 templates download from $S3_TEMPLATES_URL..."
  aws s3 sync "$S3_TEMPLATES_URL" /app/ASSETS/templates $ENDPOINT_ARG 2>&1 | while read line; do
    echo "[S3 Templates Initial Download] $line"
  done
fi

if [ -n "$S3_PLUGINS_URL" ]; then
  mkdir -p /app/ASSETS/plugins
  echo "Performing initial S3 plugins download from $S3_PLUGINS_URL..."
  aws s3 sync "$S3_PLUGINS_URL" /app/ASSETS/plugins $ENDPOINT_ARG 2>&1 | while read line; do
    echo "[S3 Plugins Initial Download] $line"
  done
fi

if [ -n "$S3_MEDIA_URL" ]; then
  mkdir -p /app/ASSETS/media
  echo "Performing initial S3 media download from $S3_MEDIA_URL..."
  aws s3 sync "$S3_MEDIA_URL" /app/ASSETS/media $ENDPOINT_ARG 2>&1 | while read line; do
    echo "[S3 Media Initial Download] $line"
  done
fi

# Start background S3 sync for templates if S3_TEMPLATES_URL is set
if [ -n "$S3_TEMPLATES_URL" ]; then
  TEMPLATES_SYNC_TARGET="/app/ASSETS/templates"
  set_sync_flags "$TEMPLATES_SOT"
  T_UPLOAD_DELETE="$UPLOAD_DELETE"
  T_DOWNLOAD_DELETE="$DOWNLOAD_DELETE"

  echo "Starting bidirectional S3 template sync with $S3_TEMPLATES_URL (source of truth: $TEMPLATES_SOT, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      aws s3 sync "$TEMPLATES_SYNC_TARGET" "$S3_TEMPLATES_URL" $T_UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Templates Upload] $line"
      done
      aws s3 sync "$S3_TEMPLATES_URL" "$TEMPLATES_SYNC_TARGET" $T_DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Templates Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for projects if S3_PROJECTS_URL is set
if [ -n "$S3_PROJECTS_URL" ]; then
  PROJECTS_SYNC_TARGET="/data"
  set_sync_flags "$PROJECTS_SOT"
  P_UPLOAD_DELETE="$UPLOAD_DELETE"
  P_DOWNLOAD_DELETE="$DOWNLOAD_DELETE"

  echo "Starting bidirectional S3 project sync with $S3_PROJECTS_URL (source of truth: $PROJECTS_SOT, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      aws s3 sync "$PROJECTS_SYNC_TARGET" "$S3_PROJECTS_URL" $P_UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Projects Upload] $line"
      done
      aws s3 sync "$S3_PROJECTS_URL" "$PROJECTS_SYNC_TARGET" $P_DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Projects Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for plugins if S3_PLUGINS_URL is set
if [ -n "$S3_PLUGINS_URL" ]; then
  PLUGINS_SYNC_TARGET="/app/ASSETS/plugins"
  set_sync_flags "$PLUGINS_SOT"
  PL_UPLOAD_DELETE="$UPLOAD_DELETE"
  PL_DOWNLOAD_DELETE="$DOWNLOAD_DELETE"

  echo "Starting bidirectional S3 plugin sync with $S3_PLUGINS_URL (source of truth: $PLUGINS_SOT, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      aws s3 sync "$PLUGINS_SYNC_TARGET" "$S3_PLUGINS_URL" $PL_UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Plugins Upload] $line"
      done
      aws s3 sync "$S3_PLUGINS_URL" "$PLUGINS_SYNC_TARGET" $PL_DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Plugins Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

# Start background S3 sync for media if S3_MEDIA_URL is set
if [ -n "$S3_MEDIA_URL" ]; then
  MEDIA_SYNC_TARGET="/app/ASSETS/media"
  set_sync_flags "$MEDIA_SOT"
  M_UPLOAD_DELETE="$UPLOAD_DELETE"
  M_DOWNLOAD_DELETE="$DOWNLOAD_DELETE"

  echo "Starting bidirectional S3 media sync with $S3_MEDIA_URL (source of truth: $MEDIA_SOT, interval: ${SYNC_INTERVAL}s)"

  (
    while true; do
      aws s3 sync "$MEDIA_SYNC_TARGET" "$S3_MEDIA_URL" $M_UPLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Media Upload] $line"
      done
      aws s3 sync "$S3_MEDIA_URL" "$MEDIA_SYNC_TARGET" $M_DOWNLOAD_DELETE $ENDPOINT_ARG 2>&1 | while read line; do
        echo "[S3 Media Download] $line"
      done
      sleep "$SYNC_INTERVAL"
    done
  ) &
fi

exec node server.js
