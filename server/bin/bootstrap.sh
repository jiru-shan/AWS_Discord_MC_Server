#!/usr/bin/env bash
# First-boot provisioning, invoked once by cloud-init from user-data.
#
# Turns a bare Amazon Linux 2023 instance into the Minecraft host: mounts the
# persistent data volume, installs Java and Node, fetches the Fabric server,
# writes the server configuration and installs the systemd unit that runs the
# server on every subsequent boot.
#
# Safe to re-run. Anything already in place is left alone, so an interrupted
# first boot can be finished by running this again.

set -euo pipefail

PAYLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$PAYLOAD_DIR/bin/common.sh"

# On the very first boot /etc/minecraft/config.env does not exist yet: user-data
# writes only the handful of values needed to reach AWS. Fetch the real
# configuration before anything below reads it. On later boots
# minecraft-refresh.service has already done this.
fetch_config() {
  [ -n "${CONFIG_SSM_PARAM:-}" ] \
    || die "CONFIG_SSM_PARAM is unset; /etc/minecraft/bootstrap.env is missing or incomplete"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  aws ssm get-parameter --name "$CONFIG_SSM_PARAM" \
    --query 'Parameter.Value' --output text > "$CONFIG_FILE.new" \
    || die "could not read $CONFIG_SSM_PARAM; check the instance IAM role"
  [ -s "$CONFIG_FILE.new" ] || die "$CONFIG_SSM_PARAM is empty"

  mv -f "$CONFIG_FILE.new" "$CONFIG_FILE"
  load_env_file "$CONFIG_FILE"
  log "loaded configuration from $CONFIG_SSM_PARAM"
}

[ -s "$CONFIG_FILE" ] || fetch_config

DATA_MOUNT="${DATA_MOUNT:-/srv/minecraft}"
SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
MC_USER="${MC_USER:-minecraft}"

log "bootstrap starting (payload at $PAYLOAD_DIR)"

# --------------------------------------------------------------------------
# Packages
# --------------------------------------------------------------------------

log "installing packages"
dnf install -y \
  "${JAVA_PACKAGE:-java-21-amazon-corretto-headless}" \
  nodejs \
  jq \
  tar \
  gzip \
  unzip \
  awscli-2 >/dev/null 2>&1 || dnf install -y \
  "${JAVA_PACKAGE:-java-21-amazon-corretto-headless}" nodejs jq tar gzip unzip

command -v java >/dev/null || die "java did not install"
command -v node >/dev/null || die "node did not install"
command -v jq >/dev/null || die "jq did not install"

# --------------------------------------------------------------------------
# Persistent data volume
#
# Kept separate from the root volume so the world survives an instance rebuild
# and can be snapshotted on its own.
# --------------------------------------------------------------------------

# Locate the data volume. Whatever this returns may get mkfs'd, so it errs
# towards returning nothing rather than returning the wrong device.
find_data_device() {
  local dev

  if [ -n "${DATA_VOLUME_ID:-}" ]; then
    # Nitro instances rename EBS volumes to unpredictable NVMe device names, but
    # AWS creates a stable by-id symlink from the volume ID with the hyphen
    # stripped. The directory is a seam so the tests can point it elsewhere.
    local by_id="${DEV_BY_ID_DIR:-/dev/disk/by-id}/nvme-Amazon_Elastic_Block_Store_${DATA_VOLUME_ID//-/}"
    [ -e "$by_id" ] && { readlink -f "$by_id"; return 0; }

    # Pre-Nitro families do not create that link but do honour the requested
    # device name.
    if [ -n "${DATA_DEVICE:-}" ] && [ -b "$DATA_DEVICE" ]; then
      readlink -f "$DATA_DEVICE"
      return 0
    fi

    # Deliberately no guessing once the volume ID is known: on an instance type
    # with local NVMe storage (anything ending in "d", such as m5d or c5d) the
    # scan below would happily pick the instance-store device and format it. The
    # world would then live on storage that is wiped on every stop. Returning
    # nothing makes the caller wait and then fail loudly instead.
    return 1
  fi

  # Only reached when no volume ID was supplied: take the one whole disk with
  # nothing mounted from it. The root disk is excluded because its partition is
  # mounted at /.
  for dev in $(lsblk -dpno NAME); do
    if [ -z "$(lsblk -no MOUNTPOINT "$dev" | tr -d ' \n')" ]; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}

mount_data_volume() {
  if mountpoint -q "$DATA_MOUNT"; then
    log "$DATA_MOUNT is already mounted"
    return 0
  fi

  local device=""
  local attempt
  for attempt in $(seq 1 30); do
    device=$(find_data_device) && [ -n "$device" ] && break
    log "waiting for the data volume to attach ($attempt/30)"
    sleep 2
  done
  [ -n "$device" ] || die "no data volume found; check the EBS attachment"
  log "data volume is $device"

  if ! blkid "$device" >/dev/null 2>&1; then
    log "formatting $device as xfs (first boot)"
    mkfs -t xfs "$device"
  else
    log "$device already has a filesystem; keeping it"
  fi

  mkdir -p "$DATA_MOUNT"
  local uuid
  uuid=$(blkid -s UUID -o value "$device")
  # nofail keeps a missing volume from wedging boot in emergency mode, where
  # there would be no SSM agent to recover through.
  if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid $DATA_MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
  fi
  mount "$DATA_MOUNT"
  log "mounted $device at $DATA_MOUNT"
}

mount_data_volume

# --------------------------------------------------------------------------
# Users and layout
# --------------------------------------------------------------------------

id -u "$MC_USER" >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin \
  --home-dir "$DATA_MOUNT" "$MC_USER"

mkdir -p "$SERVER_DIR" "$DATA_MOUNT/backups" "$INSTALL_DIR/bin"

# The payload lives on the root volume so a fresh instance always runs the code
# Terraform uploaded, not a stale copy left on the data volume.
if [ "$PAYLOAD_DIR" != "$INSTALL_DIR/payload" ]; then
  rm -rf "$INSTALL_DIR/payload"
  mkdir -p "$INSTALL_DIR/payload"
  cp -a "$PAYLOAD_DIR/." "$INSTALL_DIR/payload/"
fi
install -m 0755 "$INSTALL_DIR/payload/bin/"*.sh "$INSTALL_DIR/bin/"
install -m 0755 "$INSTALL_DIR/payload/bin/"*.js "$INSTALL_DIR/bin/"
install -m 0755 "$INSTALL_DIR/payload/bin/mc" "$MC_BIN_LINK"

# --------------------------------------------------------------------------
# Optional restore of an existing world
# --------------------------------------------------------------------------

if [ -n "${RESTORE_FROM_S3:-}" ] && [ ! -e "$SERVER_DIR/world" ]; then
  log "restoring world from $RESTORE_FROM_S3"
  tmp=$(mktemp -d)
  if aws s3 cp "$RESTORE_FROM_S3" "$tmp/restore.tar.gz" --only-show-errors; then
    tar -xzf "$tmp/restore.tar.gz" -C "$SERVER_DIR"
    log "restore complete"
  else
    log "WARNING: restore failed; starting from a fresh world"
  fi
  rm -rf "$tmp"
fi

# --------------------------------------------------------------------------
# Fabric server jar
#
# Fabric's meta API hands out a launcher jar for any (game, loader, installer)
# triple. The launcher downloads the vanilla server and libraries on its first
# run, so nothing else needs fetching here.
# --------------------------------------------------------------------------

install_server_jar() {
  local jar="$SERVER_DIR/${SERVER_JAR:-server.jar}"

  # First boot only. On every later boot update-server-jar.sh decides whether
  # the jar should be replaced, by comparing it against minecraft_version.
  if [ -s "$jar" ] && [ "${FORCE_JAR_REINSTALL:-false}" != "true" ]; then
    log "server jar already present; leaving it alone"
    return 0
  fi

  local url="${SERVER_JAR_URL:-}"
  if [ -n "$url" ]; then
    log "installing server jar from $url"
    curl -fsSL --retry 3 -o "$jar.tmp" "$url" || die "failed to download the server jar"
    [ -s "$jar.tmp" ] || die "downloaded server jar is empty"
    mv "$jar.tmp" "$jar"
    return 0
  fi

  local game
  game=$(resolve_game_version) || die "could not resolve a Minecraft version from meta.fabricmc.net"
  install_fabric_jar "$game" || die "could not install the Fabric server jar"
}

install_server_jar

# --------------------------------------------------------------------------
# Server configuration
#
# Written only when absent, so hand edits on the instance survive a re-run.
# --------------------------------------------------------------------------

if [ "${ACCEPT_EULA:-false}" != "true" ]; then
  die "ACCEPT_EULA is not true; set accept_minecraft_eula in Terraform to run a server"
fi
printf 'eula=true\n' > "$SERVER_DIR/eula.txt"

if [ ! -f "$SERVER_DIR/server.properties" ]; then
  log "writing server.properties"
  cat > "$SERVER_DIR/server.properties" <<PROPS
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
spawn-protection=0
sync-chunk-writes=false
# Left at 0: idle shutdown is handled by servermanager.js, which needs the
# server responsive so it can save and stop cleanly.
pause-when-empty-seconds=0
PROPS
fi

# ops.json / whitelist.json are only seeded on a fresh install; after that the
# in-game /op and /whitelist commands own them.
#
# The splitting and trimming is done in the shell rather than inside a jq
# program, so jq is only ever asked to encode one object at a time. That keeps
# the part that can go wrong -- handling of spaces, empty entries and trailing
# commas -- in code the tests can exercise directly.
seed_player_list() {
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
}
seed_player_list ops.json "${SERVER_OPS:-}"
seed_player_list whitelist.json "${SERVER_WHITELIST_PLAYERS:-}"

chown -R "$MC_USER:$MC_USER" "$DATA_MOUNT"

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------

log "installing systemd units"
install -m 0644 "$INSTALL_DIR/payload/systemd/"*.service "$SYSTEMD_DIR/"
systemctl daemon-reload
systemctl enable minecraft-refresh.service minecraft.service

log "bootstrap complete; starting the server"
systemctl start --no-block minecraft.service
