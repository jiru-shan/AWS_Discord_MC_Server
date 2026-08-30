#!/usr/bin/env bash
# Reconcile the Terraform-managed keys in server.properties, on every boot.
#
# Off unless manage_server_properties is true, because the default contract is
# the opposite one: bootstrap.sh writes server.properties once and never touches
# it again, so an edit made on the instance is never reverted. That is the right
# default for a file the server itself rewrites and people tune by hand.
#
# The cost of it is that `server_motd = "..."` followed by an apply does nothing
# on an instance that already exists, and the only fix is a shell. Turning this
# on trades the hand edits away and makes those settings behave like every other
# setting: change them in Terraform, apply, restart.
#
# Only the keys below are touched. Anything else in the file -- a setting you
# added by hand, a key a mod reads -- is copied through untouched, so this is a
# reconcile of the managed subset rather than a regeneration of the file.
set -uo pipefail
. "$(dirname "$0")/common.sh"

SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
PROPS="$SERVER_DIR/server.properties"

[ "${MANAGE_SERVER_PROPERTIES:-false}" = "true" ] || exit 0

# Nothing to reconcile before the first one exists; bootstrap.sh writes it.
[ -f "$PROPS" ] || { log "no server.properties yet; nothing to reconcile"; exit 0; }

# The keys Terraform owns, and the values it currently says they should have.
# Kept in one place so the list here and the one bootstrap.sh writes cannot
# drift apart silently.
managed_pairs() {
  cat <<PAIRS
server-port=${SERVER_PORT:-25565}
motd=${SERVER_MOTD:-A Minecraft Server}
difficulty=${SERVER_DIFFICULTY:-normal}
gamemode=${SERVER_GAMEMODE:-survival}
max-players=${SERVER_MAX_PLAYERS:-10}
view-distance=${SERVER_VIEW_DISTANCE:-10}
simulation-distance=${SERVER_SIMULATION_DISTANCE:-10}
white-list=${SERVER_WHITELIST:-false}
enforce-whitelist=${SERVER_WHITELIST:-false}
online-mode=${SERVER_ONLINE_MODE:-true}
PAIRS
}

# The configured value for one key, or non-zero if Terraform does not own it.
managed_value() {
  local key="$1" pair
  while IFS= read -r pair; do
    case "$pair" in
      "$key="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done <<< "$(managed_pairs)"
  return 1
}

tmp="$PROPS.new"
: > "$tmp"
seen=""

# Rewrite in place, preserving order, comments and blank lines. A properties
# file is read top to bottom and the last assignment wins, so keeping position
# rather than appending matters when a key already appears twice.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*|'!'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
    *=*) ;;
    *) printf '%s\n' "$line" >> "$tmp"; continue ;;
  esac

  key=${line%%=*}
  if value=$(managed_value "$key"); then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    seen="$seen $key "
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$PROPS"

# A managed key the file never had -- a new setting, or a file written by an
# older version of this project.
while IFS= read -r pair; do
  key=${pair%%=*}
  case "$seen" in
    *" $key "*) continue ;;
  esac
  printf '%s\n' "$pair" >> "$tmp"
  seen="$seen $key "
done <<< "$(managed_pairs)"

if cmp -s "$PROPS" "$tmp"; then
  rm -f "$tmp"
  log "server.properties already matches the configuration"
  exit 0
fi

# Keep one copy of what was there before. This overwrites hand edits by design,
# and "by design" is not much comfort at the moment you realise it.
cp -p "$PROPS" "$PROPS.bak" 2>/dev/null || true
chown "${MC_USER:-minecraft}:${MC_USER:-minecraft}" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$PROPS"
log "server.properties reconciled with the Terraform configuration (previous copy at $PROPS.bak)"
