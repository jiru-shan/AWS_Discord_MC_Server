#!/usr/bin/env bash
# ExecStopPost for minecraft.service: back the world up, then power off if the
# stop was intended.
#
# The sentinel is what separates "the server finished its session" from "an
# admin stopped the service to work on it". Without it the instance stays up.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# Bounded, because everything after it is what actually stops the billing.
# systemd allows the whole stop sequence TimeoutStopSec (300s) and then kills
# it, and this backup has no natural ceiling: tar, gzip and an S3 upload of a
# world that grows every session. Once that runs past the budget the SIGKILL
# lands here, the `shutdown -h now` below is never reached, and the instance is
# left up with no server on it and nothing that will try again. A backup that
# cannot finish in the time available is worth losing; the session it would
# otherwise cost is not.
backup_budget="${STOP_BACKUP_TIMEOUT_SECONDS:-180}"
timeout -k 15 "$backup_budget" "$INSTALL_DIR/bin/backup.sh"   || log "backup failed or exceeded ${backup_budget}s; continuing to the shutdown decision"

# systemd sets SERVICE_RESULT for ExecStopPost. It is "success" for a clean exit
# and for an operator-requested stop, and something else when the unit failed --
# including a failed ExecStartPre, which is the case that matters here: if
# announce-address.sh cannot publish the address, the server never starts, and
# without this the instance would sit there billing with nothing running on it.
result="${SERVICE_RESULT:-success}"

# instance_initiated_shutdown_behavior is "stop", so powering off stops rather
# than terminates the instance, and both EBS volumes survive.
if [ -f "$RUN_DIR/idle-shutdown" ]; then
  reason=$(cat "$RUN_DIR/idle-shutdown")
  log "shutdown sentinel present (${reason}); powering off"
  shutdown -h now
elif [ "$result" != "success" ] && [ "${SHUTDOWN_ON_CRASH:-true}" = "true" ]; then
  log "service ended abnormally (${result}) with no sentinel; powering off to stop the billing"
  notify "Minecraft server failed to start (${result}). Shutting the instance down."
  shutdown -h now
else
  log "no shutdown sentinel; leaving the instance running for maintenance"
fi
