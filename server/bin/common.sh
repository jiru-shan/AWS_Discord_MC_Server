#!/usr/bin/env bash
# Shared helpers for the on-instance scripts. Source this, do not execute it.
#
# Every tunable lives in /etc/minecraft/config.env, which is refreshed from SSM
# Parameter Store on each boot. That file is also loaded by systemd as an
# EnvironmentFile, so the same names are visible to servermanager.js.

BOOTSTRAP_FILE="${BOOTSTRAP_FILE:-/etc/minecraft/bootstrap.env}"
CONFIG_FILE="${CONFIG_FILE:-/etc/minecraft/config.env}"
RUN_DIR="${RUN_DIR:-/run/minecraft}"
# Scripts on the root volume, world data on the mounted volume.
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft}"
DATA_MOUNT="${DATA_MOUNT:-/srv/minecraft}"

# Where the install steps put things outside INSTALL_DIR. Overridable so the
# whole install path can be exercised against a throwaway root.
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
MC_BIN_LINK="${MC_BIN_LINK:-/usr/local/bin/mc}"

# Read a KEY="value" environment file without letting the shell interpret the
# values.
#
# Sourcing the file would be shorter, but it expands $, backticks and
# backslashes inside the values. That turns a server MOTD containing a dollar
# sign into silent breakage, and a MOTD containing $(...) into arbitrary code
# running as root at boot. Only parameter expansion is used below, so nothing in
# the file can execute.
#
# The unescaping matches how systemd reads the same file as an EnvironmentFile:
# strip one layer of surrounding double quotes, then turn \\ into \ and \" into
# a quote.
load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac

    key=${line%%=*}
    value=${line#*=}

    # Keys come from Terraform, but refuse anything that is not a plain
    # environment variable name rather than exporting something strange.
    case "$key" in
      [A-Za-z_]*) ;;
      *) continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*) continue ;;
    esac

    case "$value" in
      '"'*'"') value=${value#\"}; value=${value%\"} ;;
    esac
    # Park escaped backslashes on a control character so the following
    # substitution cannot mistake "\\\"" for an escaped quote.
    value=${value//\\\\/$'\001'}
    value=${value//\\\"/\"}
    value=${value//$'\001'/\\}

    export "$key=$value"
  done < "$file"
}

# bootstrap.env is written once by user-data and holds only what is needed to
# reach AWS. config.env holds everything else and is refreshed from SSM on every
# boot, so it is loaded second and wins on any overlap.
load_env_file "$BOOTSTRAP_FILE"
load_env_file "$CONFIG_FILE"

export AWS_DEFAULT_REGION="${AWS_REGION:-us-west-2}"

mkdir -p "$RUN_DIR"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

# --------------------------------------------------------------------------
# Instance metadata (IMDSv2)
# --------------------------------------------------------------------------

imds() {
  # -m: the retry loop in public_ipv4 bounds the number of attempts, not how
  # long any one of them can sit there. IMDS is link-local and answers in
  # milliseconds or not at all, so five seconds is already generous.
  local token
  token=$(curl -fsS -m 5 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null) || return 1
  curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}

# Public IPv4 of this instance. Retries because the address is not always
# attached the instant the network comes up, especially with an Elastic IP.
# The budget is tunable so the tests do not sit through a full minute of it.
public_ipv4() {
  local attempt ip
  for attempt in $(seq 1 "${IMDS_ATTEMPTS:-30}"); do
    ip=$(imds public-ipv4) && [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep "${IMDS_RETRY_SECONDS:-2}"
  done
  return 1
}

instance_id() {
  imds instance-id
}

# --------------------------------------------------------------------------
# Connect address
# --------------------------------------------------------------------------

# The address players type into Minecraft. Written to $RUN_DIR/address by
# announce-address.sh so later scripts do not each have to work it out.
connect_address() {
  if [ -s "$RUN_DIR/address" ]; then
    cat "$RUN_DIR/address"
    return 0
  fi
  case "${ADDRESSING_MODE:-none}" in
    route53)     echo "${ROUTE53_RECORD_NAME%.}" ;;
    elastic_ip)  echo "${STATIC_ADDRESS:-$(public_ipv4)}" ;;
    *)           public_ipv4 ;;
  esac
}

# Address with the port appended, unless it is the default 25565.
connect_address_with_port() {
  local address
  address=$(connect_address) || return 1
  if [ "${SERVER_PORT:-25565}" = "25565" ]; then
    echo "$address"
  else
    echo "$address:${SERVER_PORT}"
  fi
}

# --------------------------------------------------------------------------
# Fabric server jar
#
# Shared by bootstrap.sh, which installs the jar on the first boot, and
# update-server-jar.sh, which replaces it when minecraft_version changes.
# --------------------------------------------------------------------------

# Newest stable entry from one of Fabric's meta lists: game, loader or
# installer.
fabric_latest() {
  curl -fsS -m 30 "https://meta.fabricmc.net/v2/versions/$1" \
    | jq -r '[.[] | select(.stable == true)][0].version'
}

# Resolve MINECRAFT_VERSION to a concrete game version. "latest" -- or unset --
# means whatever Fabric currently calls stable.
resolve_game_version() {
  local game="${MINECRAFT_VERSION:-latest}"
  [ "$game" = "latest" ] && game=$(fabric_latest game)
  [ -n "$game" ] || return 1
  echo "$game"
}

# Download the Fabric launcher for one game version into $SERVER_DIR, and
# record which version it is.
#
# The launcher fetches the vanilla server and libraries on its first run, so
# this is the only download needed. It lands on a .tmp file and is renamed, so
# an interrupted download cannot leave a truncated jar for the JVM to choke on.
install_fabric_jar() {
  local game="$1"
  local jar="$SERVER_DIR/${SERVER_JAR:-server.jar}"
  local loader="${FABRIC_LOADER_VERSION:-latest}" installer url

  [ "$loader" = "latest" ] && loader=$(fabric_latest loader)
  installer=$(fabric_latest installer)
  if [ -z "$game" ] || [ -z "$loader" ] || [ -z "$installer" ]; then
    log "ERROR: could not resolve Fabric versions from meta.fabricmc.net"
    return 1
  fi

  log "installing Fabric: Minecraft $game, loader $loader, installer $installer"
  url="https://meta.fabricmc.net/v2/versions/loader/$game/$loader/$installer/server/jar"

  if ! curl -fsSL -m 300 --retry 3 -o "$jar.tmp" "$url"; then
    log "ERROR: failed to download the server jar"
    rm -f "$jar.tmp"
    return 1
  fi
  if [ ! -s "$jar.tmp" ]; then
    log "ERROR: downloaded server jar is empty"
    rm -f "$jar.tmp"
    return 1
  fi

  mv "$jar.tmp" "$jar"
  # Written only after the jar is in place, so the two can never disagree.
  echo "$game" > "$SERVER_DIR/.minecraft-version"
}

# The game version of the jar currently installed, or nothing if unknown.
installed_game_version() {
  local file="$SERVER_DIR/.minecraft-version"
  [ -s "$file" ] || return 1
  # Trimmed: a stray newline or carriage return here would make an identical
  # version compare unequal and trigger a pointless reinstall on every boot.
  tr -d '[:space:]' < "$file"
}

# --------------------------------------------------------------------------
# Discord
# --------------------------------------------------------------------------

# The webhook URL is a secret, so it is kept in SSM Parameter Store rather than
# baked into the AMI or config file. Cache it in /run (tmpfs) for the boot.
webhook_url() {
  [ -n "${DISCORD_WEBHOOK_SSM_PARAM:-}" ] || return 1

  if [ ! -s "$RUN_DIR/webhook.url" ]; then
    aws ssm get-parameter \
      --name "$DISCORD_WEBHOOK_SSM_PARAM" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text > "$RUN_DIR/webhook.url" 2>/dev/null || return 1
    chmod 600 "$RUN_DIR/webhook.url"
  fi

  # An unset SSM parameter comes back as the literal string "None".
  local url
  url=$(cat "$RUN_DIR/webhook.url")
  [ -n "$url" ] && [ "$url" != "None" ] || return 1
  echo "$url"
}

# Post a message to the Discord channel. Never fails the caller -- a missing or
# broken webhook must not stop the server from running.
notify() {
  local message="$1" url payload
  url=$(webhook_url) || { log "notify (no webhook configured): $message"; return 0; }

  payload=$(jq -nc \
    --arg content "$message" \
    --arg username "${DISCORD_USERNAME:-Minecraft Server}" \
    '{content: $content, username: $username, allowed_mentions: {parse: []}}')

  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "$payload" "$url" >/dev/null 2>&1 \
    || log "notify failed (webhook rejected or unreachable): $message"
  return 0
}
