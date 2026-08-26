#!/usr/bin/env bash
# Graceful shutdown requested from Discord (/stop), run through SSM.
#
# Writes the sentinel first so that however the service ends -- through
# servermanager's own stop handling or systemd's SIGTERM -- on-stop.sh knows the
# power-off was intended.
set -euo pipefail
. "$(dirname "$0")/common.sh"

echo requested > "$RUN_DIR/idle-shutdown"
log "stop requested; stopping minecraft.service"
systemctl stop minecraft.service
