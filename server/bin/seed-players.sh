#!/usr/bin/env bash
# Seed ops.json and whitelist.json from server_ops and server_whitelist_players.
#
# Runs on every boot, as an ExecStartPre of minecraft.service, and writes each
# file only when it does not already exist. That guard is the whole design:
#
#   - Set server_ops before you ever start, and you are an operator on the very
#     first join, with no console access needed.
#   - Once the file exists, the in-game /op and /whitelist commands own it. This
#     script never touches it again, so a player you added at 2am is not undone
#     by the next boot.
#
# Running every boot rather than only during bootstrap.sh matters for the
# common case: somebody deploys, plays for a week, then decides they want a
# whitelist. bootstrap.sh only ever runs once, so a value added later would
# otherwise be silently ignored, and the only symptom is a whitelist that stays
# empty for no visible reason.
set -uo pipefail
. "$(dirname "$0")/common.sh"

SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
MC_USER="${MC_USER:-minecraft}"

[ -d "$SERVER_DIR" ] || { log "no server directory yet; nothing to seed"; exit 0; }

# The splitting and trimming is done in the shell rather than inside a jq
# program, so jq is only ever asked to encode one object at a time. That keeps
# the part that can go wrong -- handling of spaces, empty entries and trailing
# commas -- in code the tests can exercise directly.
seed_player_list() { # seed_player_list <file> <comma-separated names>
  local file="$1" names="$2" name entries=()
  [ -n "$names" ] || return 0
  [ -f "$SERVER_DIR/$file" ] && return 0

  local IFS=','
  read -ra raw <<< "$names"
  unset IFS

  for name in "${raw[@]}"; do
    # Trim surrounding whitespace, then skip anything that was only whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [ -n "$name" ] || continue

    if [ "$file" = "ops.json" ]; then
      entries+=("$(jq -nc --arg n "$name" --argjson l "${OP_LEVEL:-4}" \
        '{uuid: "", name: $n, level: $l, bypassesPlayerLimit: false}')")
    else
      entries+=("$(jq -nc --arg n "$name" '{uuid: "", name: $n}')")
    fi
  done

  [ ${#entries[@]} -gt 0 ] || return 0
  log "seeding $file with ${#entries[@]} entries"
  printf '[%s]\n' "$(IFS=,; echo "${entries[*]}")" > "$SERVER_DIR/$file"
  chown "$MC_USER:$MC_USER" "$SERVER_DIR/$file" 2>/dev/null || true
}

seed_player_list ops.json "${SERVER_OPS:-}"
seed_player_list whitelist.json "${SERVER_WHITELIST_PLAYERS:-}"

exit 0
