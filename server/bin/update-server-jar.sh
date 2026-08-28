#!/usr/bin/env bash
# Reconcile the installed server jar with minecraft_version, on every boot.
#
# Runs as an ExecStartPre of minecraft.service, before install-mods.js, so a
# version change re-resolves the mods for the new version in the same start.
#
# Without this, `minecraft_version` would only take effect on a rebuilt
# instance: bootstrap.sh installs the jar once and leaves it alone from then on,
# which is right for a script that also formats disks and creates users, but
# leaves the setting a lie on a running server.
#
# Deliberately never fails the boot. If an upgrade cannot be completed the old
# jar is still in place and still works; the server comes up on the version it
# was already running and says so in the journal and in Discord. A failed
# upgrade should cost you a version, not an evening.
set -uo pipefail
. "$(dirname "$0")/common.sh"

SERVER_DIR="${SERVER_DIR:-$DATA_MOUNT/server}"
JAR="$SERVER_DIR/${SERVER_JAR:-server.jar}"
FORCE="${FORCE_JAR_REINSTALL:-false}"

# A pinned jar URL means the operator is managing the jar themselves; there is
# no version to compare against and no meta API that describes it.
if [ -n "${SERVER_JAR_URL:-}" ]; then
  log "server_jar_url is set; leaving the jar alone"
  exit 0
fi

[ -d "$SERVER_DIR" ] || { log "no server directory yet; nothing to reconcile"; exit 0; }

configured="${MINECRAFT_VERSION:-latest}"
installed=$(installed_game_version) || installed=""

# --------------------------------------------------------------------------
# Decide
# --------------------------------------------------------------------------

# Upgrading is world-affecting and irreversible, so each branch below has to
# earn it. The default is to do nothing.
reason=""

if [ ! -s "$JAR" ]; then
  # Recovery rather than upgrade: something removed the jar, or a restore
  # brought back a world without one.
  reason="no server jar present"

elif [ "$FORCE" = "true" ]; then
  reason="forced reinstall"

elif [ "$configured" = "latest" ]; then
  # "latest" is resolved once, when the jar is first installed, and then
  # sticks. Following it automatically would upgrade the world the first time
  # Mojang shipped a release -- with no backup taken by anyone's intent, no
  # check that the mods have builds for it, and no way back, because worlds do
  # not downgrade. Pin the version to move deliberately.
  log "minecraft_version is \"latest\"; staying on ${installed:-the installed version}"
  exit 0

elif [ -z "$installed" ]; then
  # A jar with no .minecraft-version beside it: pre-dates this script, or was
  # put there by hand. Its version is genuinely unknown, and reinstalling on a
  # guess could silently upgrade a world.
  log "a server jar is installed but its version is unrecorded; not touching it"
  log "to move to $configured deliberately: sudo mc upgrade"
  exit 0

elif [ "$installed" = "$configured" ]; then
  exit 0

else
  reason="minecraft_version changed: $installed -> $configured"
fi

# --------------------------------------------------------------------------
# Act
# --------------------------------------------------------------------------

log "$reason"

target="$configured"
if [ "$target" = "latest" ]; then
  target=$(resolve_game_version) || {
    log "WARNING: could not resolve the latest Minecraft version; leaving the jar alone"
    exit 0
  }
fi

# Back up before replacing the jar, but only when there is a world to lose.
# Worlds do not downgrade: once the new version has opened it, the only way
# back to the old one is this archive.
if [ -d "$SERVER_DIR/world" ] && [ -n "$installed" ] && [ "$installed" != "$target" ]; then
  log "backing up before the upgrade"
  if ! "$INSTALL_DIR/bin/backup.sh"; then
    # Refusing here is the cautious choice and the right one: an upgrade with
    # no way back is worse than staying a version behind.
    log "ERROR: backup failed; refusing to upgrade $installed -> $target"
    notify "Minecraft upgrade to $target was skipped: the pre-upgrade backup failed. Still on $installed."
    exit 0
  fi
fi

if install_fabric_jar "$target"; then
  log "server jar is now Minecraft $target"
  [ -n "$installed" ] && [ "$installed" != "$target" ] \
    && notify "Minecraft updated from $installed to $target."
else
  log "WARNING: could not install Minecraft $target"
  if [ -s "$JAR" ]; then
    log "keeping the jar already installed (${installed:-unknown version})"
    notify "Minecraft update to $target failed; still running ${installed:-the previous version}."
  else
    # No jar at all: servermanager.js will fail immediately and report it.
    # Nothing useful left to do here.
    log "ERROR: there is no server jar to fall back to"
  fi
fi

exit 0
