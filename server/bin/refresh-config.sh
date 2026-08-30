#!/usr/bin/env bash
# Pull the current configuration and scripts from AWS on every boot.
#
# Runs as minecraft-refresh.service, ordered before minecraft.service. Without
# this, a `terraform apply` that changes (say) the idle timeout would only take
# effect on a rebuilt instance, because cloud-init user-data runs once.
#
# Deliberately forgiving: if AWS cannot be reached, the copies already on disk
# are kept and the server still starts. A config refresh failing is not a reason
# to leave people unable to play.
set -uo pipefail
. "$(dirname "$0")/common.sh"

if [ -n "${CONFIG_SSM_PARAM:-}" ]; then
  tmp=$(mktemp)
  if aws ssm get-parameter --name "$CONFIG_SSM_PARAM" \
       --query 'Parameter.Value' --output text > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    install -m 0644 "$tmp" "$CONFIG_FILE"
    log "configuration refreshed from $CONFIG_SSM_PARAM"
  else
    log "WARNING: could not read $CONFIG_SSM_PARAM; keeping the existing configuration"
  fi
  rm -f "$tmp"
fi

if [ -n "${PAYLOAD_BUCKET:-}" ]; then
  "$INSTALL_DIR/bin/update-payload.sh" \
    || log "WARNING: payload refresh failed; keeping the scripts already installed"
fi

exit 0
