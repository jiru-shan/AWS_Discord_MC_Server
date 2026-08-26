#!/usr/bin/env bash
# Snapshot the world and configuration.
#
# Normally runs from on-stop.sh once the server process has already exited, so
# the world is flushed to disk. It is also safe to run by hand while the server
# is up: it pauses world saving through the admin console first.
#
# Backups go to S3 when a bucket is configured (retention is handled there by a
# lifecycle rule) and the most recent few are also kept on the data volume for
# a quick local restore.
set -euo pipefail
. "$(dirname "$0")/common.sh"

SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
BACKUP_DIR="${BACKUP_DIR:-$DATA_MOUNT/backups}"
KEEP="${LOCAL_BACKUP_KEEP:-3}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$BACKUP_DIR/minecraft-$STAMP.tar.gz"

[ -d "$SERVER_DIR" ] || die "server directory $SERVER_DIR does not exist"
mkdir -p "$BACKUP_DIR"

# If the server is still running, stop it writing to the region files mid-tar.
server_running=false
if systemctl is-active --quiet minecraft.service && [ -p "$RUN_DIR/console" ]; then
  server_running=true
  log "server is running; flushing and pausing world saves"
  { echo "save-off"; echo "save-all flush"; } > "$RUN_DIR/console"
  sleep 5
fi

restore_saving() {
  if [ "$server_running" = true ]; then
    echo "save-on" > "$RUN_DIR/console" || true
  fi
}
trap restore_saving EXIT

log "creating $ARCHIVE"
# The excluded paths are all re-downloadable or regenerated on next boot; they
# are also the bulk of the directory, so leaving them out keeps backups small.
tar -czf "$ARCHIVE" -C "$SERVER_DIR" \
  --exclude='./logs' \
  --exclude='./crash-reports' \
  --exclude='./libraries' \
  --exclude='./versions' \
  --exclude='./.fabric' \
  --exclude='./cache' \
  . || die "tar failed"

restore_saving
trap - EXIT

log "archive size: $(du -h "$ARCHIVE" | cut -f1)"

if [ -n "${BACKUP_BUCKET:-}" ]; then
  target="s3://$BACKUP_BUCKET/${BACKUP_PREFIX:-backups}/minecraft-$STAMP.tar.gz"
  log "uploading to $target"
  if aws s3 cp "$ARCHIVE" "$target" --only-show-errors; then
    log "upload complete"
  else
    log "WARNING: upload failed; the local copy in $BACKUP_DIR is the only one"
  fi
else
  log "no BACKUP_BUCKET configured; keeping local backups only"
fi

# Rotate local copies, newest first.
mapfile -t stale < <(ls -1t "$BACKUP_DIR"/minecraft-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))")
for old in "${stale[@]:-}"; do
  [ -n "$old" ] || continue
  log "removing old local backup $old"
  rm -f "$old"
done
