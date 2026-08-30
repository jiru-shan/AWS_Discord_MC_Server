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
#
# Every entry needs a real UUID. An entry with an empty one looks fine on disk
# and does nothing: the server cannot turn it into a profile, so it drops the
# entry, and on the boot that creates the world it rewrites the file without it
# -- which is precisely the boot this script exists for. A name that cannot be
# resolved is therefore skipped and said out loud, rather than written as an
# entry that silently grants nothing.
set -uo pipefail
. "$(dirname "$0")/common.sh"

SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
MC_USER="${MC_USER:-minecraft}"

[ -d "$SERVER_DIR" ] || { log "no server directory yet; nothing to seed"; exit 0; }

# md5, wherever it lives. Linux has md5sum; macOS, which the test suite also
# runs on, has md5 instead.
md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    openssl dgst -md5 | sed 's/.*= *//'
  fi
}

# The UUID an offline-mode server derives for a name, which is what Java's
# UUID.nameUUIDFromBytes produces over "OfflinePlayer:<name>": an MD5 with the
# version nibble forced to 3 and the variant bits to 10xx.
offline_uuid() {
  local name="$1" h variant packed
  h=$(printf 'OfflinePlayer:%s' "$name" | md5_hex)
  [ ${#h} -eq 32 ] || return 1
  variant=$(printf '%x' $(((0x${h:16:1} & 0x3) | 0x8)))
  packed="${h:0:12}3${h:13:3}${variant}${h:17:3}${h:20:12}"
  printf '%s-%s-%s-%s-%s' \
    "${packed:0:8}" "${packed:8:4}" "${packed:12:4}" "${packed:16:4}" "${packed:20:12}"
}

# The UUID the running server will accept for this name.
resolve_uuid() {
  local name="$1" id
  if [ "${SERVER_ONLINE_MODE:-true}" != "true" ]; then
    offline_uuid "$name"
    return
  fi
  id=$(curl -fsS -m 10 "https://api.mojang.com/users/profiles/minecraft/$name" 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null) || return 1
  [ ${#id} -eq 32 ] || return 1
  printf '%s-%s-%s-%s-%s' \
    "${id:0:8}" "${id:8:4}" "${id:12:4}" "${id:16:4}" "${id:20:12}"
}

# The splitting and trimming is done in the shell rather than inside a jq
# program, so jq is only ever asked to encode one object at a time. That keeps
# the part that can go wrong -- handling of spaces, empty entries and trailing
# commas -- in code the tests can exercise directly.
seed_player_list() { # seed_player_list <file> <comma-separated names>
  local file="$1" names="$2" name uuid entries=() skipped=0
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

    if ! uuid=$(resolve_uuid "$name"); then
      log "WARNING: could not resolve a UUID for \"$name\"; leaving it out of $file"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$file" = "ops.json" ]; then
      entries+=("$(jq -nc --arg n "$name" --arg u "$uuid" --argjson l "${OP_LEVEL:-4}" \
        '{uuid: $u, name: $n, level: $l, bypassesPlayerLimit: false}')")
    else
      entries+=("$(jq -nc --arg n "$name" --arg u "$uuid" '{uuid: $u, name: $n}')")
    fi
  done

  if [ ${#entries[@]} -eq 0 ]; then
    # Writing an empty list would create the file, and the file existing is what
    # stops this script ever trying again. Leave it absent so the next boot can.
    [ "$skipped" -gt 0 ] && log "no usable entries for $file; not creating it"
    return 0
  fi

  log "seeding $file with ${#entries[@]} entries"
  printf '[%s]\n' "$(IFS=,; echo "${entries[*]}")" > "$SERVER_DIR/$file"
  chown "$MC_USER:$MC_USER" "$SERVER_DIR/$file" 2>/dev/null || true
}

seed_player_list ops.json "${SERVER_OPS:-}"
seed_player_list whitelist.json "${SERVER_WHITELIST_PLAYERS:-}"

exit 0
