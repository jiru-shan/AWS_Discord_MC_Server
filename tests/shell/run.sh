#!/usr/bin/env bash
# End-to-end tests for the on-instance scripts.
#
# Each test gets a throwaway filesystem root, a stubbed AWS CLI, systemctl,
# shutdown, curl and jq, and then runs the real scripts unmodified. Nothing here
# touches AWS or the machine it runs on.
#
# Run with: bash tests/shell/run.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STUB_SRC="$HERE/stubs"

PASS=0
FAIL=0
CURRENT=""

# --------------------------------------------------------------------------
# Test framework
# --------------------------------------------------------------------------

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$CURRENT" "$1" >&2
}

pass() { PASS=$((PASS + 1)); }

check() { # check <description> <condition-result> [detail]
  if [ "$2" = "0" ]; then pass; else fail "$1${3:+ -- $3}"; fi
}

assert_eq() { # assert_eq <expected> <actual> <what>
  if [ "$1" = "$2" ]; then pass; else fail "$3: expected [$1], got [$2]"; fi
}

assert_contains() { # assert_contains <haystack> <needle> <what>
  case "$1" in *"$2"*) pass ;; *) fail "$3: [$2] not found in [$1]" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) fail "$3: [$2] should not appear in [$1]" ;; *) pass ;; esac
}

assert_file() { [ -e "$1" ] && pass || fail "$2: expected file $1 to exist"; }
assert_no_file() { [ -e "$1" ] && fail "$2: file $1 should not exist" || pass; }

# --------------------------------------------------------------------------
# Fixture
# --------------------------------------------------------------------------

# Written by setup(); exported so the stubs can see them.
export STUB_DIR STUB_LOG STUB_SSM_DIR

setup() { # setup <test name> [extra config.env lines...]
  CURRENT="$1"; shift
  printf '\n%s\n' "$CURRENT"

  ROOT=$(mktemp -d)
  STUB_DIR="$ROOT/stub"
  STUB_LOG="$STUB_DIR/calls.log"
  STUB_SSM_DIR="$STUB_DIR/ssm"
  mkdir -p "$STUB_DIR" "$STUB_SSM_DIR" "$STUB_DIR/s3-objects"
  : > "$STUB_LOG"

  INSTALL_DIR="$ROOT/opt/minecraft"
  DATA_MOUNT="$ROOT/srv/minecraft"
  SERVER_DIR="$DATA_MOUNT/server"
  RUN_DIR="$ROOT/run/minecraft"
  ETC="$ROOT/etc/minecraft"
  mkdir -p "$INSTALL_DIR/bin" "$SERVER_DIR" "$DATA_MOUNT/backups" "$RUN_DIR" "$ETC"

  # The real scripts, unmodified.
  cp "$REPO/server/bin/"*.sh "$REPO/server/bin/mc" "$INSTALL_DIR/bin/"
  chmod +x "$INSTALL_DIR/bin/"*

  cat > "$ETC/bootstrap.env" <<ENVEOF
AWS_REGION="us-west-2"
CONFIG_SSM_PARAM="/minecraft/config"
PAYLOAD_BUCKET="test-bucket"
PAYLOAD_KEY="payload/server.zip"
ENVEOF

  # Mirrors what Terraform generates, pointed at the throwaway root.
  {
    cat <<ENVEOF
AWS_REGION="us-west-2"
INSTALL_DIR="$INSTALL_DIR"
DATA_MOUNT="$DATA_MOUNT"
SERVER_DIR="$SERVER_DIR"
SERVER_PORT="25565"
ADDRESSING_MODE="none"
DISCORD_WEBHOOK_SSM_PARAM=""
DISCORD_USERNAME="Minecraft Server"
BACKUP_BUCKET=""
BACKUP_PREFIX="backups"
LOCAL_BACKUP_KEEP="3"
SHUTDOWN_ON_CRASH="true"
CONFIG_SSM_PARAM="/minecraft/config"
PAYLOAD_BUCKET="test-bucket"
PAYLOAD_KEY="payload/server.zip"
ENVEOF
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$ETC/config.env"

  export BOOTSTRAP_FILE="$ETC/bootstrap.env"
  export CONFIG_FILE="$ETC/config.env"
  export RUN_DIR
  # mc is installed outside INSTALL_DIR (at /usr/local/bin), so it locates
  # common.sh through this rather than through $0.
  export INSTALL_DIR DATA_MOUNT
  # Keep the install steps inside the throwaway root.
  export SYSTEMD_DIR="$ROOT/etc/systemd/system"
  export MC_BIN_LINK="$ROOT/usr/local/bin/mc"
  mkdir -p "$SYSTEMD_DIR" "$(dirname "$MC_BIN_LINK")"
  export PATH="$STUBS:$PATH"

  # bash leaves a `VAR=1 func` prefix set after the call returns, so every stub
  # switch has to be cleared here or it bleeds into the following tests.
  unset STUB_SERVICE_ACTIVE STUB_IMDS_FAIL STUB_NO_PUBLIC_IP STUB_ROUTE53_FAIL \
        STUB_S3_FAIL STUB_SSM_FAIL STUB_WEBHOOK_FAIL SERVICE_RESULT \
        STUB_JAR_FAIL STUB_JAR_EMPTY STUB_FABRIC_META_FAIL STUB_FABRIC_GAME \
        STUB_PUBLIC_IP STOP_BACKUP_TIMEOUT_SECONDS
}

teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }

run_script() { # run_script <name> [args...] -> stdout+stderr, sets RC
  local name="$1"; shift
  # A timeout so a script that blocks fails the test instead of hanging the run.
  OUT=$(cd "$ROOT" && timeout 30 "$INSTALL_DIR/bin/$name" "$@" 2>&1)
  RC=$?
  [ "$RC" = "124" ] && fail "$CURRENT: $name timed out"
}

# Drain a FIFO for the rest of the test. Opened read-write, exactly as
# servermanager.js does, so it never sees EOF when one writer closes -- a plain
# "cat fifo" exits after the first write and the next writer blocks forever.
drain_fifo() {
  local fifo="$1" out="$2"
  mkfifo "$fifo" 2>/dev/null
  ( exec 3<> "$fifo"; timeout 20 cat <&3 > "$out" ) &
  DRAIN=$!
  sleep 0.1
}

# --------------------------------------------------------------------------
# Safety: never let a test reach the real shutdown binary.
# --------------------------------------------------------------------------

# The stubs run from a throwaway copy, not from the working tree, so that a
# checkout which lost the executable bit -- a ZIP download of the repository, a
# clone made under core.fileMode=false -- still shadows the real binaries.
# Without this, `shutdown` resolves to /usr/sbin/shutdown and the guard below
# stops the suite dead on a perfectly healthy tree.
STUBS=$(mktemp -d)
trap 'rm -rf "$STUBS"' EXIT
cp "$STUB_SRC"/* "$STUBS/"
chmod +x "$STUBS"/*

export PATH="$STUBS:$PATH"
resolved=$(command -v shutdown || true)
case "$resolved" in
  "$STUBS/shutdown") ;;
  *)
    echo "REFUSING TO RUN: 'shutdown' resolves to '$resolved', not the stub." >&2
    echo "Running the suite could power off this machine, so it stops here." >&2
    echo "This is the harness protecting you, not a failure of the project." >&2
    echo "Something is shadowing PATH: check that $STUB_SRC/shutdown exists." >&2
    exit 1
    ;;
esac
echo "safety check: shutdown resolves to the stub"

# ==========================================================================
# common.sh: configuration loading
# ==========================================================================

setup "config values are never evaluated by the shell"
MARKER="$ROOT/PWNED"
cat >> "$CONFIG_FILE" <<ENVEOF
SERVER_MOTD="\$(touch $MARKER)Danger \`touch $MARKER\` \$HOME \$5"
ENVEOF
run_script_out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; printf '%s' \"\$SERVER_MOTD\"" 2>&1)
assert_no_file "$MARKER" "command substitution in a config value must not execute"
assert_contains "$run_script_out" 'touch' "the literal text should survive"
assert_contains "$run_script_out" '$HOME' "a dollar sign must not be expanded"
assert_contains "$run_script_out" '$5' "a positional-looking value must not be expanded"
teardown

setup "quoted and escaped config values round-trip"
cat >> "$CONFIG_FILE" <<'ENVEOF'
SERVER_MOTD="Bob\"s \\ server"
EMPTY_VALUE=""
SPACED="  leading and trailing  "
ENVEOF
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; printf '%s|%s|%s' \"\$SERVER_MOTD\" \"\$EMPTY_VALUE\" \"\$SPACED\"" 2>&1)
assert_eq 'Bob"s \ server||  leading and trailing  ' "$out" "escapes should be undone exactly once"
teardown

setup "malformed config lines are skipped, not fatal"
cat >> "$CONFIG_FILE" <<'ENVEOF'

# a comment
not_an_assignment
1INVALID="x"
BAD-KEY="x"
GOOD_KEY="kept"
ENVEOF
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; printf '%s' \"\$GOOD_KEY\"" 2>&1)
RC=$?
assert_eq "0" "$RC" "a malformed line must not abort loading"
assert_eq "kept" "$out" "later valid keys still load"
teardown

setup "every escape sequence Terraform can emit decodes back to the original"
# Terraform writes KEY="value" after flattening newlines, doubling backslashes
# and escaping quotes, in that order. These are the exact byte sequences that
# process can produce; each must decode back to the value on the right.
cat >> "$CONFIG_FILE" <<'ENVEOF'
T_PLAIN="hello world"
T_QUOTE="say \"hi\""
T_BACKSLASH="C:\path\to"
T_TRAILING_BACKSLASH="ends with\\"
T_QUOTE_THEN_BACKSLASH="a\"b\\"
T_LITERAL_NEWLINE_ESCAPE="line one\nline two"
T_DOLLARS="costs $5 and $HOME"
T_BACKTICKS="a `b` c"
T_MIXED="Bob\"s \ server $USER"
T_UNICODE="Café ✦ サーバー"
ENVEOF
read_value() {
  cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; printf '%s' \"\${$1}\"" 2>&1
}
assert_eq 'hello world'            "$(read_value T_PLAIN)"                   "plain value"
assert_eq 'say "hi"'               "$(read_value T_QUOTE)"                   "escaped quotes"
assert_eq 'C:\path\to'             "$(read_value T_BACKSLASH)"               "doubled backslashes"
assert_eq 'ends with\'             "$(read_value T_TRAILING_BACKSLASH)"      "backslash at end of value"
assert_eq 'a"b\'                   "$(read_value T_QUOTE_THEN_BACKSLASH)"    "quote then trailing backslash"
assert_eq 'line one\nline two'     "$(read_value T_LITERAL_NEWLINE_ESCAPE)"  "server.properties style \n stays literal"
assert_eq 'costs $5 and $HOME'     "$(read_value T_DOLLARS)"                 "dollars are literal"
assert_eq 'a `b` c'                "$(read_value T_BACKTICKS)"               "backticks are literal"
assert_eq 'Bob"s \ server $USER'   "$(read_value T_MIXED)"                   "all three at once"
assert_eq 'Café ✦ サーバー'         "$(read_value T_UNICODE)"                 "non-ascii survives"
teardown

setup "systemd and common.sh agree on the same config file"
# The file is read twice: by systemd as an EnvironmentFile for minecraft.service,
# and by common.sh for the shell scripts. Both strip one layer of double quotes
# and both turn \" into a quote, so a value must not need different escaping for
# the two readers. Assert the format stays within that shared subset.
cat >> "$CONFIG_FILE" <<'ENVEOF'
T_SHARED="a \"quoted\" value"
ENVEOF
generated=$(grep '^T_SHARED=' "$CONFIG_FILE")
assert_eq 'T_SHARED="a \"quoted\" value"' "$generated" "the on-disk form both readers see"
assert_eq 'a "quoted" value' "$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; printf '%s' \"\$T_SHARED\"")" \
  "and what the shell side decodes"
teardown

# ==========================================================================
# common.sh: address resolution
# ==========================================================================

setup "connect address falls back to the instance public IP" 'ADDRESSING_MODE="none"'
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; connect_address" 2>&1)
assert_eq "203.0.113.10" "$out" "should read IMDS"
teardown

setup "connect address prefers the file written at boot" 'ADDRESSING_MODE="none"'
echo "mc.example.com" > "$RUN_DIR/address"
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; connect_address" 2>&1)
assert_eq "mc.example.com" "$out" "the cached address wins"
teardown

setup "a non-default port is appended" 'SERVER_PORT="25570"' 'ADDRESSING_MODE="route53"' 'ROUTE53_RECORD_NAME="mc.example.com"'
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; connect_address_with_port" 2>&1)
assert_eq "mc.example.com:25570" "$out" "port should be shown"
teardown

setup "the default port is not appended" 'ADDRESSING_MODE="route53"' 'ROUTE53_RECORD_NAME="mc.example.com."'
out=$(cd "$ROOT" && bash -c ". '$INSTALL_DIR/bin/common.sh'; connect_address_with_port" 2>&1)
assert_eq "mc.example.com" "$out" "trailing dot stripped, port omitted"
teardown

# ==========================================================================
# notify
# ==========================================================================

setup "notify posts well-formed JSON to the webhook" 'DISCORD_WEBHOOK_SSM_PARAM="/minecraft/discord-webhook-url"'
echo "https://discord.com/api/webhooks/1/abc" > "$STUB_SSM_DIR/_minecraft_discord-webhook-url"
run_script notify.sh 'Server is up at `1.2.3.4`'
assert_eq "0" "$RC" "notify should succeed"
posted=$(cat "$STUB_DIR/webhook-posts" 2>/dev/null || echo "")
assert_contains "$posted" '"content":"Server is up at `1.2.3.4`"' "content should be encoded"
assert_contains "$posted" '"allowed_mentions":{"parse":[]}' "mentions must be suppressed"
teardown

setup "notify is a no-op when no webhook is configured"
run_script notify.sh 'hello'
assert_eq "0" "$RC" "must not fail the caller"
assert_contains "$OUT" "no webhook configured" "should say so"
teardown

setup "a failing webhook does not fail the caller" 'DISCORD_WEBHOOK_SSM_PARAM="/minecraft/discord-webhook-url"'
echo "https://discord.com/api/webhooks/1/abc" > "$STUB_SSM_DIR/_minecraft_discord-webhook-url"
STUB_WEBHOOK_FAIL=1 run_script notify.sh 'hello'
assert_eq "0" "$RC" "a broken webhook must never break the server"
assert_contains "$OUT" "notify failed" "should log the failure"
teardown

setup "an unset SSM parameter reads as no webhook" 'DISCORD_WEBHOOK_SSM_PARAM="/minecraft/discord-webhook-url"'
echo "None" > "$STUB_SSM_DIR/_minecraft_discord-webhook-url"
run_script notify.sh 'hello'
assert_eq "0" "$RC" "should not fail"
assert_contains "$OUT" "no webhook configured" "the literal None must not be used as a URL"
teardown

# ==========================================================================
# announce-address.sh
# ==========================================================================

setup "route53 mode publishes the current IP" \
  'ADDRESSING_MODE="route53"' 'ROUTE53_ZONE_ID="Z123"' 'ROUTE53_RECORD_NAME="mc.example.com"' 'ROUTE53_TTL="30"'
run_script announce-address.sh
assert_eq "0" "$RC" "should succeed"
batch=$(cat "$STUB_DIR/route53-change-batch.json")
assert_contains "$batch" '"Action":"UPSERT"' "must upsert"
assert_contains "$batch" '"Name":"mc.example.com"' "correct record"
assert_contains "$batch" '"Value":"203.0.113.10"' "the IP from IMDS"
assert_contains "$batch" '"TTL":30' "TTL as a number, not a string"
assert_eq "Z123" "$(cat "$STUB_DIR/route53-zone-id")" "correct zone"
assert_eq "mc.example.com" "$(cat "$RUN_DIR/address")" "address file written"
teardown

setup "a route53 failure aborts the boot" \
  'ADDRESSING_MODE="route53"' 'ROUTE53_ZONE_ID="Z123"' 'ROUTE53_RECORD_NAME="mc.example.com"'
STUB_ROUTE53_FAIL=1 run_script announce-address.sh
check "should exit non-zero so systemd sees the failure" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
assert_contains "$OUT" "Route 53 update failed" "should explain why"
assert_no_file "$RUN_DIR/address" "must not claim an address it did not publish"
teardown

setup "route53 mode without a zone id fails loudly" 'ADDRESSING_MODE="route53"' 'ROUTE53_RECORD_NAME="mc.example.com"'
run_script announce-address.sh
check "should refuse to continue" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
assert_contains "$OUT" "ROUTE53_ZONE_ID is unset" "should name the missing setting"
teardown

setup "elastic ip mode uses the static address and calls no APIs" \
  'ADDRESSING_MODE="elastic_ip"' 'STATIC_ADDRESS="198.51.100.7"'
run_script announce-address.sh
assert_eq "0" "$RC" "should succeed"
assert_eq "198.51.100.7" "$(cat "$RUN_DIR/address")" "static address used"
assert_not_contains "$(cat "$STUB_LOG")" "route53" "no DNS call in elastic ip mode"
teardown

setup "no addressing mode records the raw IP" 'ADDRESSING_MODE="none"'
run_script announce-address.sh
assert_eq "203.0.113.10" "$(cat "$RUN_DIR/address")" "raw IP recorded"
teardown

setup "a broken IMDS aborts rather than publishing nothing" 'ADDRESSING_MODE="none"'
export IMDS_ATTEMPTS=2 IMDS_RETRY_SECONDS=0
STUB_IMDS_FAIL=1 run_script announce-address.sh
unset IMDS_ATTEMPTS IMDS_RETRY_SECONDS
check "should fail" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
assert_contains "$OUT" "could not read this instance" "should say what went wrong"
teardown

# ==========================================================================
# backup.sh
# ==========================================================================

setup "backup archives the world and skips regenerable directories"
mkdir -p "$SERVER_DIR/world" "$SERVER_DIR/logs" "$SERVER_DIR/libraries" "$SERVER_DIR/mods"
echo "region data" > "$SERVER_DIR/world/r.0.0.mca"
echo "config" > "$SERVER_DIR/server.properties"
echo "log noise" > "$SERVER_DIR/logs/latest.log"
echo "jar" > "$SERVER_DIR/libraries/lib.jar"
echo "mod" > "$SERVER_DIR/mods/lithium.jar"
run_script backup.sh
assert_eq "0" "$RC" "backup should succeed"
archive=$(ls "$DATA_MOUNT/backups"/minecraft-*.tar.gz 2>/dev/null | head -1)
assert_file "$archive" "an archive should be produced"
listing=$(tar -tzf "$archive")
assert_contains "$listing" "world/r.0.0.mca" "the world must be in the backup"
assert_contains "$listing" "server.properties" "configuration must be in the backup"
assert_contains "$listing" "mods/lithium.jar" "mods must be in the backup"
assert_not_contains "$listing" "logs/latest.log" "logs should be excluded"
assert_not_contains "$listing" "libraries/lib.jar" "libraries should be excluded"
teardown

setup "backup uploads to S3 when a bucket is configured" 'BACKUP_BUCKET="my-bucket"'
mkdir -p "$SERVER_DIR/world"; echo x > "$SERVER_DIR/world/r.mca"
run_script backup.sh
assert_eq "0" "$RC" "should succeed"
uploads=$(cat "$STUB_DIR/s3-uploads" 2>/dev/null || echo "")
assert_contains "$uploads" "s3://my-bucket/backups/minecraft-" "uploaded to the right prefix"
teardown

setup "a failed upload keeps the local copy and does not fail the stop" 'BACKUP_BUCKET="my-bucket"'
mkdir -p "$SERVER_DIR/world"; echo x > "$SERVER_DIR/world/r.mca"
STUB_S3_FAIL=1 run_script backup.sh
assert_eq "0" "$RC" "an upload failure must not fail the backup"
assert_contains "$OUT" "upload failed" "should warn"
check "local archive still present" "$(ls "$DATA_MOUNT/backups"/*.tar.gz >/dev/null 2>&1 && echo 0 || echo 1)"
teardown

setup "old local backups are rotated out" 'LOCAL_BACKUP_KEEP="3"'
mkdir -p "$SERVER_DIR/world"; echo x > "$SERVER_DIR/world/r.mca"
for i in 1 2 3 4 5; do
  touch -d "2020-01-0$i" "$DATA_MOUNT/backups/minecraft-2020010${i}T000000Z.tar.gz" 2>/dev/null \
    || touch "$DATA_MOUNT/backups/minecraft-2020010${i}T000000Z.tar.gz"
  sleep 0.01
done
run_script backup.sh
count=$(ls -1 "$DATA_MOUNT/backups"/minecraft-*.tar.gz | wc -l)
assert_eq "3" "$(echo "$count" | tr -d ' ')" "should keep exactly LOCAL_BACKUP_KEEP archives"
teardown

setup "backup pauses world saving while the server is running"
mkdir -p "$SERVER_DIR/world"; echo x > "$SERVER_DIR/world/r.mca"
drain_fifo "$RUN_DIR/console" "$STUB_DIR/console-commands"
STUB_SERVICE_ACTIVE=1 run_script backup.sh
sleep 0.3; kill $DRAIN 2>/dev/null
sent=$(cat "$STUB_DIR/console-commands" 2>/dev/null || echo "")
assert_contains "$sent" "save-off" "saving must be paused before the tar"
assert_contains "$sent" "save-all flush" "the world must be flushed to disk first"
assert_contains "$sent" "save-on" "saving must be resumed afterwards"
teardown

setup "backup refuses to run without a server directory"
rm -rf "$SERVER_DIR"
run_script backup.sh
check "should fail" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
assert_contains "$OUT" "does not exist" "should explain"
teardown

# ==========================================================================
# on-stop.sh: the shutdown decision
# ==========================================================================

setup "an idle stop powers the instance off"
mkdir -p "$SERVER_DIR/world"
echo idle > "$RUN_DIR/idle-shutdown"
SERVICE_RESULT=success run_script on-stop.sh
assert_file "$STUB_DIR/shutdown-calls" "the sentinel must cause a power-off"
assert_contains "$(cat "$STUB_LOG")" "shutdown -h now" "should stop, not terminate"
teardown

setup "a maintenance stop leaves the instance running"
mkdir -p "$SERVER_DIR/world"
SERVICE_RESULT=success run_script on-stop.sh
assert_no_file "$STUB_DIR/shutdown-calls" "no sentinel means no power-off"
assert_contains "$OUT" "leaving the instance running" "should say why"
teardown

setup "a failed start still powers the instance off"
mkdir -p "$SERVER_DIR/world"
SERVICE_RESULT=exit-code run_script on-stop.sh
assert_file "$STUB_DIR/shutdown-calls" "a failed unit must not be left billing"
assert_contains "$OUT" "ended abnormally" "should explain"
teardown

setup "shutdown_on_crash=false keeps a failed instance up for debugging" 'SHUTDOWN_ON_CRASH="false"'
mkdir -p "$SERVER_DIR/world"
SERVICE_RESULT=exit-code run_script on-stop.sh
assert_no_file "$STUB_DIR/shutdown-calls" "the operator asked to keep it up"
teardown

setup "a backup failure does not prevent the shutdown"
rm -rf "$SERVER_DIR"
echo idle > "$RUN_DIR/idle-shutdown"
SERVICE_RESULT=success run_script on-stop.sh
assert_file "$STUB_DIR/shutdown-calls" "the instance must still power off"
assert_contains "$OUT" "backup failed" "should warn about the backup"
teardown

setup "a backup runs before the power-off"
mkdir -p "$SERVER_DIR/world"; echo x > "$SERVER_DIR/world/r.mca"
echo idle > "$RUN_DIR/idle-shutdown"
SERVICE_RESULT=success run_script on-stop.sh
check "an archive should exist" "$(ls "$DATA_MOUNT/backups"/*.tar.gz >/dev/null 2>&1 && echo 0 || echo 1)"
assert_file "$STUB_DIR/shutdown-calls" "and then power off"
teardown

setup "a backup that never finishes cannot block the power-off"
# systemd kills the whole stop sequence at TimeoutStopSec, and this backup has
# no natural ceiling: tar, gzip and an S3 upload of a world that grows every
# session. Once it runs past the budget the kill lands before `shutdown -h now`
# and the instance is left up with no server on it and nothing to try again.
mkdir -p "$SERVER_DIR/world"
echo idle > "$RUN_DIR/idle-shutdown"
cat > "$INSTALL_DIR/bin/backup.sh" <<'HANG'
#!/usr/bin/env bash
sleep 120
HANG
chmod +x "$INSTALL_DIR/bin/backup.sh"
STOP_BACKUP_TIMEOUT_SECONDS=2 SERVICE_RESULT=success run_script on-stop.sh
assert_file "$STUB_DIR/shutdown-calls" "a stuck backup must not keep the instance billing"
assert_contains "$OUT" "exceeded 2s" "should say the backup was cut short"
teardown

# ==========================================================================
# user-data: the first boot
#
# The one failure path in this project with no backstop. cloud-init runs this
# once and never retries, and until it has installed minecraft.service there is
# no ExecStopPost to power the instance off -- so anything that exits non-zero
# here leaves a box billing with nothing running on it.
# ==========================================================================

render_user_data() { # -> $ROOT/user-data.sh, rooted in the throwaway tree
  sed -e 's|${bootstrap_env}|AWS_REGION="us-west-2"|' \
      -e 's|${payload_bucket}|test-bucket|g' \
      -e 's|${payload_key}|payload/server.zip|g' \
      -e 's|${region}|us-west-2|g' \
      -e 's|${shutdown_on_crash}|true|g' \
      -e "s|/etc/minecraft|$ROOT/etc/minecraft|g" \
      -e "s|/opt/minecraft|$ROOT/opt/minecraft|g" \
      "$REPO/terraform/templates/user_data.sh.tftpl" > "$ROOT/user-data.sh"
}

run_user_data() { # -> sets OUT and RC
  OUT=$(cd "$ROOT" && PATH="$STUB_DIR/bin:$PATH" timeout 30 bash "$ROOT/user-data.sh" 2>&1)
  RC=$?
}

setup "a first boot that dies before bootstrap.sh still powers the instance off"
render_user_data
mkdir -p "$STUB_DIR/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/bin/dnf"
chmod +x "$STUB_DIR/bin/dnf"
run_user_data
check "user-data should fail when the package install does" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)" "exit was $RC"
assert_file "$STUB_DIR/shutdown-calls" "a dnf hiccup must not leave an instance billing forever"
assert_contains "$(cat "$STUB_LOG")" "shutdown -h +30" "with a window to read the log over SSM"
teardown

setup "a first boot that fails inside bootstrap.sh also powers the instance off"
render_user_data
mkdir -p "$STUB_DIR/bin" "$ROOT/opt/minecraft/payload/bin" "$STUB_DIR/s3-objects"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/bin/dnf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/bin/unzip"
printf 'payload\n' > "$STUB_DIR/s3-objects/server.zip"
printf '#!/usr/bin/env bash\nexit 9\n' > "$ROOT/opt/minecraft/payload/bin/bootstrap.sh"
chmod +x "$STUB_DIR/bin/dnf" "$STUB_DIR/bin/unzip" "$ROOT/opt/minecraft/payload/bin/bootstrap.sh"
run_user_data
assert_eq "9" "$RC" "the bootstrap exit status should survive"
assert_file "$STUB_DIR/shutdown-calls" "the original guard must keep working"
assert_contains "$(cat "$STUB_LOG")" "shutdown -h +30" "same half hour window"
teardown

# ==========================================================================
# request-stop.sh
# ==========================================================================

setup "a requested stop writes the sentinel before stopping the service"
run_script request-stop.sh
assert_eq "0" "$RC" "should succeed"
assert_file "$RUN_DIR/idle-shutdown" "the sentinel must exist"
assert_eq "requested" "$(cat "$RUN_DIR/idle-shutdown")" "recorded reason"
assert_contains "$(cat "$STUB_LOG")" "systemctl stop minecraft.service" "should stop the unit"
teardown

# ==========================================================================
# refresh-config.sh
# ==========================================================================

setup "boot-time refresh replaces the configuration from SSM"
printf 'IDLE_TIMEOUT_MINUTES="45"\nSERVER_MOTD="refreshed"\n' > "$STUB_SSM_DIR/_minecraft_config"
run_script refresh-config.sh
assert_eq "0" "$RC" "should succeed"
assert_contains "$(cat "$CONFIG_FILE")" 'IDLE_TIMEOUT_MINUTES="45"' "new config installed"
teardown

setup "a refresh failure keeps the previous configuration"
before=$(cat "$CONFIG_FILE")
STUB_SSM_FAIL=1 run_script refresh-config.sh
assert_eq "0" "$RC" "must not block the server from starting"
assert_eq "$before" "$(cat "$CONFIG_FILE")" "the old configuration must survive"
assert_contains "$OUT" "keeping the existing configuration" "should say so"
teardown

setup "an empty SSM parameter does not blank the configuration"
: > "$STUB_SSM_DIR/_minecraft_config"
before=$(cat "$CONFIG_FILE")
run_script refresh-config.sh
assert_eq "$before" "$(cat "$CONFIG_FILE")" "an empty response must be rejected"
teardown

# ==========================================================================
# update-payload.sh
# ==========================================================================

setup "the payload update replaces scripts without corrupting the running one"
mkdir -p "$ROOT/newpayload/bin" "$ROOT/newpayload/systemd"
cp "$REPO/server/bin/"*.sh "$REPO/server/bin/mc" "$ROOT/newpayload/bin/"
cp "$REPO/server/bin/servermanager.js" "$ROOT/newpayload/bin/"
cp "$REPO/server/systemd/"*.service "$ROOT/newpayload/systemd/"
echo "# marker for the updated copy" >> "$ROOT/newpayload/bin/notify.sh"
python -c "
import os, sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, names in os.walk(src):
        for name in names:
            full = os.path.join(root, name)
            z.write(full, os.path.relpath(full, src))
" "$ROOT/newpayload" "$STUB_DIR/s3-objects/server.zip"
mkdir -p "$INSTALL_DIR/payload"
run_script update-payload.sh
assert_eq "0" "$RC" "the update should succeed even though it rewrites itself"
assert_contains "$(cat "$INSTALL_DIR/bin/notify.sh")" "marker for the updated copy" "new scripts installed"
assert_contains "$(cat "$STUB_LOG")" "systemctl daemon-reload" "units reloaded"
assert_file "$SYSTEMD_DIR/minecraft.service" "unit files installed"
assert_file "$MC_BIN_LINK" "the admin CLI is installed"
teardown

setup "a payload update failure is reported, not silent"
run_script update-payload.sh
check "should fail when the object is missing" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
teardown

# ==========================================================================
# mc
# ==========================================================================

setup "mc reports status and address" 'ADDRESSING_MODE="none"'
run_script mc status
assert_contains "$OUT" "connect address: 203.0.113.10" "status should show the address"
teardown

setup "mc console refuses when the server is not running"
run_script mc console list
check "should fail" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
assert_contains "$OUT" "server is not running" "should explain"
teardown

setup "mc console forwards a command to the server"
drain_fifo "$RUN_DIR/console" "$STUB_DIR/console-commands"
run_script mc console list
sleep 0.3; kill $DRAIN 2>/dev/null
assert_contains "$(cat "$STUB_DIR/console-commands" 2>/dev/null || echo)" "list" "the command should reach the FIFO"
teardown

setup "mc maintenance-stop clears the sentinel so the box stays up"
echo idle > "$RUN_DIR/idle-shutdown"
run_script mc maintenance-stop
assert_no_file "$RUN_DIR/idle-shutdown" "the sentinel must be cleared"
assert_contains "$(cat "$STUB_LOG")" "systemctl stop minecraft.service" "the service should stop"
teardown

setup "mc rejects an unknown command"
run_script mc frobnicate
assert_eq "1" "$RC" "should exit non-zero"
assert_contains "$OUT" "unknown command" "should say so"
teardown

setup "mc with no arguments prints usage"
run_script mc
assert_eq "0" "$RC" "help is not an error"
assert_contains "$OUT" "Usage: mc" "should print usage"
teardown

# ==========================================================================
# bootstrap.sh helpers
# ==========================================================================

setup "the data volume is located by its stable by-id name"
mkdir -p "$ROOT/byid"
: > "$ROOT/byid/nvme-Amazon_Elastic_Block_Store_vol0abc123"
out=$(cd "$ROOT" && bash -c "
  . '$INSTALL_DIR/bin/common.sh'
  DEV_BY_ID_DIR='$ROOT/byid'
  DATA_VOLUME_ID='vol-0abc123'
  $(sed -n '/^find_data_device()/,/^}/p' "$REPO/server/bin/bootstrap.sh")
  find_data_device
" 2>&1)
assert_contains "$out" "nvme-Amazon_Elastic_Block_Store_vol0abc123"   "the hyphen must be stripped from the volume id to form the symlink name"
teardown

setup "a known volume id never falls back to guessing a device"
out=$(cd "$ROOT" && bash -c "
  . '$INSTALL_DIR/bin/common.sh'
  DEV_BY_ID_DIR='$ROOT/nonexistent'
  DATA_VOLUME_ID='vol-0abc123'
  DATA_DEVICE='/dev/does-not-exist'
  export STUB_LSBLK_DISKS='/dev/nvme0n1:/
/dev/nvme1n1:'
  $(sed -n '/^find_data_device()/,/^}/p' "$REPO/server/bin/bootstrap.sh")
  find_data_device
  echo \"rc=\$?\"
" 2>&1)
assert_contains "$out" "rc=1" "with a known volume id, no candidate must be an error"
assert_not_contains "$out" "/dev/nvme1n1"   "guessing here could format an instance-store device on a *d instance type"
teardown

setup "the by-id lookup is preferred over the requested device name"
mkdir -p "$ROOT/byid"
: > "$ROOT/byid/nvme-Amazon_Elastic_Block_Store_vol0abc123"
out=$(cd "$ROOT" && bash -c "
  . '$INSTALL_DIR/bin/common.sh'
  DEV_BY_ID_DIR='$ROOT/byid'
  DATA_VOLUME_ID='vol-0abc123'
  $(sed -n '/^find_data_device()/,/^}/p' "$REPO/server/bin/bootstrap.sh")
  find_data_device
" 2>&1)
assert_contains "$out" "nvme-Amazon_Elastic_Block_Store_vol0abc123" "by-id wins"
teardown

setup "without a volume id the scan skips the disk holding the root filesystem"
out=$(cd "$ROOT" && bash -c "
  . '$INSTALL_DIR/bin/common.sh'
  unset DATA_VOLUME_ID
  export STUB_LSBLK_DISKS='/dev/nvme0n1:/
/dev/nvme1n1:'
  $(sed -n '/^find_data_device()/,/^}/p' "$REPO/server/bin/bootstrap.sh")
  find_data_device
" 2>&1)
assert_eq "/dev/nvme1n1" "$out" "must pick the unmounted disk, never the booted one"
teardown

setup "without a volume id and no spare disk, the scan reports failure"
out=$(cd "$ROOT" && bash -c "
  . '$INSTALL_DIR/bin/common.sh'
  unset DATA_VOLUME_ID
  export STUB_LSBLK_DISKS='/dev/nvme0n1:/'
  $(sed -n '/^find_data_device()/,/^}/p' "$REPO/server/bin/bootstrap.sh")
  find_data_device
  echo \"rc=\$?\"
" 2>&1)
assert_contains "$out" "rc=1" "no candidate must be an error"
assert_not_contains "$out" "/dev/nvme0n1" "the root disk must never be offered"
teardown

setup "seeding produces valid JSON and trims whitespace" \
  'SERVER_OPS=" Alice , Bob ,, Carol "'
run_script seed-players.sh
ops=$(cat "$SERVER_DIR/ops.json")
assert_contains "$ops" '"name":"Alice"' "first name"
assert_contains "$ops" '"name":"Carol"' "name after an empty entry"
assert_not_contains "$ops" '" Bob "' "surrounding whitespace should be trimmed"
count=$(python -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$SERVER_DIR/ops.json" 2>/dev/null)
assert_eq "3" "$count" "an empty entry must not become a player"
teardown

setup "ops are seeded with an op level, whitelist entries without one" \
  'SERVER_OPS="Alice"' 'SERVER_WHITELIST_PLAYERS="Bob"'
run_script seed-players.sh
assert_contains "$(cat "$SERVER_DIR/ops.json")" '"level":4' "ops need a level"
assert_not_contains "$(cat "$SERVER_DIR/whitelist.json")" "level" "whitelist entries do not"
teardown

setup "seeding never clobbers a list the server owns" 'SERVER_OPS="Alice"'
# Once the file exists, in-game /op owns it. Overwriting on a later boot would
# silently undo every change made since the deploy.
printf '[{"uuid":"u","name":"Existing","level":4}]' > "$SERVER_DIR/ops.json"
run_script seed-players.sh
ops=$(cat "$SERVER_DIR/ops.json")
assert_contains "$ops" "Existing" "in-game changes must survive"
assert_not_contains "$ops" "Alice" "and the seed must not be re-applied"
teardown

setup "seeding does nothing for an empty list"
run_script seed-players.sh
assert_eq "0" "$RC" "exit code"
assert_no_file "$SERVER_DIR/ops.json" "no file should be created"
assert_no_file "$SERVER_DIR/whitelist.json" "and none for the whitelist either"
teardown

setup "a whitelist added long after the first boot still takes effect" \
  'SERVER_WHITELIST_PLAYERS="Alice,Bob"'
# The case this script exists for: bootstrap.sh ran once, weeks ago, with no
# whitelist configured. Adding one now has to work without rebuilding.
run_script seed-players.sh
assert_file "$SERVER_DIR/whitelist.json" "the list should appear on this boot"
assert_contains "$(cat "$SERVER_DIR/whitelist.json")" "Bob" "both names"
teardown

setup "seeding survives a missing server directory" 'SERVER_OPS="Alice"'
rm -rf "$SERVER_DIR"
run_script seed-players.sh
assert_eq "0" "$RC" "must not fail the boot"
teardown

setup "mc version shows both the installed and the configured version" \
  'MINECRAFT_VERSION="1.21.4"'
printf '1.21.3\n' > "$SERVER_DIR/.minecraft-version"
run_script mc version
assert_contains "$OUT" "installed:  1.21.3" "installed version"
assert_contains "$OUT" "configured: 1.21.4" "configured version"
teardown

setup "mc version says so when the installed version was never recorded"
run_script mc version
assert_contains "$OUT" "unrecorded" "it must not invent a version"
teardown

setup "mc upgrade refuses without --yes" 'MINECRAFT_VERSION="1.21.4"'
# The upgrade is irreversible, so it asks once rather than acting on a typo.
printf 'old-jar-body' > "$SERVER_DIR/server.jar"
printf '1.21.3\n' > "$SERVER_DIR/.minecraft-version"
run_script mc upgrade
check "exits non-zero without confirmation" "$([ "$RC" != "0" ] && echo 0 || echo 1)"
assert_contains "$OUT" "do not downgrade" "it should say why it is asking"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "nothing may change"
teardown

setup "mc upgrade refuses while the server is running" 'MINECRAFT_VERSION="1.21.4"'
printf 'old-jar-body' > "$SERVER_DIR/server.jar"
printf '1.21.3\n' > "$SERVER_DIR/.minecraft-version"
STUB_SERVICE_ACTIVE=1 run_script mc upgrade --yes
check "exits non-zero while active" "$([ "$RC" != "0" ] && echo 0 || echo 1)"
assert_contains "$OUT" "maintenance-stop" "it should name the way to proceed"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "nothing may change"
teardown

setup "mc upgrade --yes moves a server pinned to latest" 'MINECRAFT_VERSION="latest"'
# The boot-time check deliberately declines this case; the explicit command is
# how you move a "latest" server when you actually mean to.
printf 'old-jar-body' > "$SERVER_DIR/server.jar"
printf '1.21.3\n' > "$SERVER_DIR/.minecraft-version"
run_script mc upgrade --yes
assert_eq "stub-fabric-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar should be replaced"
assert_eq "1.21.4" "$(cat "$SERVER_DIR/.minecraft-version")" "and the newest stable recorded"
teardown

# ==========================================================================
# update-server-jar.sh: reconciling the jar with minecraft_version
#
# The upgrade is irreversible -- worlds do not downgrade -- so most of what
# follows is about the cases where it must decline to act.
# ==========================================================================

# Put a jar and a recorded version in place, as a booted server would have.
seed_jar() { # seed_jar [recorded version]
  printf 'old-jar-body' > "$SERVER_DIR/server.jar"
  [ $# -gt 0 ] && printf '%s\n' "$1" > "$SERVER_DIR/.minecraft-version"
  return 0
}

setup "a pinned version change replaces the jar and records the new version" \
  'MINECRAFT_VERSION="1.21.4"' 'BACKUP_BUCKET=""'
seed_jar "1.21.3"
mkdir -p "$SERVER_DIR/world"
run_script update-server-jar.sh
assert_eq "0" "$RC" "the boot must never be failed by this script"
assert_contains "$OUT" "1.21.3 -> 1.21.4" "the reason should name both versions"
assert_eq "1.21.4" "$(cat "$SERVER_DIR/.minecraft-version")" "recorded version"
assert_eq "stub-fabric-jar-body" "$(cat "$SERVER_DIR/server.jar")" "jar replaced"
backups=$(ls "$DATA_MOUNT/backups" 2>/dev/null)
assert_contains "$backups" "minecraft-" "a backup must be taken before an irreversible upgrade"
teardown

setup "an unchanged pinned version does nothing at all" 'MINECRAFT_VERSION="1.21.4"'
seed_jar "1.21.4"
run_script update-server-jar.sh
assert_eq "0" "$RC" "exit code"
assert_no_file "$STUB_DIR/jar-downloads" "nothing should have been downloaded"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar must be untouched"
teardown

setup 'minecraft_version = "latest" never upgrades on its own' 'MINECRAFT_VERSION="latest"'
# Following "latest" automatically would upgrade a world the first time Mojang
# shipped a release, with no backup anyone intended and no way back.
seed_jar "1.21.3"
run_script update-server-jar.sh
assert_contains "$OUT" "staying on 1.21.3" "it should say it is holding position"
assert_no_file "$STUB_DIR/jar-downloads" "no download"
assert_eq "1.21.3" "$(cat "$SERVER_DIR/.minecraft-version")" "recorded version unchanged"
teardown

setup "a jar with no recorded version is left alone" 'MINECRAFT_VERSION="1.21.4"'
# Its real version is unknown, so reinstalling would be a guess that could
# silently upgrade a world.
seed_jar
run_script update-server-jar.sh
assert_contains "$OUT" "unrecorded" "it should say why it declined"
assert_contains "$OUT" "mc upgrade" "and name the deliberate way to proceed"
assert_no_file "$STUB_DIR/jar-downloads" "no download"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar must be untouched"
teardown

setup "a missing jar is reinstalled rather than left missing" 'MINECRAFT_VERSION="1.21.4"'
run_script update-server-jar.sh
assert_contains "$OUT" "no server jar present" "the reason"
assert_eq "stub-fabric-jar-body" "$(cat "$SERVER_DIR/server.jar")" "jar installed"
assert_eq "1.21.4" "$(cat "$SERVER_DIR/.minecraft-version")" "version recorded"
teardown

setup "a missing jar with latest resolves the version from Fabric" 'MINECRAFT_VERSION="latest"'
run_script update-server-jar.sh
assert_eq "1.21.4" "$(cat "$SERVER_DIR/.minecraft-version")" "the newest stable from the meta stub"
teardown

setup "a failed download keeps the jar already installed" 'MINECRAFT_VERSION="1.21.4"'
seed_jar "1.21.3"
STUB_JAR_FAIL=1 run_script update-server-jar.sh
assert_eq "0" "$RC" "a failed upgrade must not fail the boot"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the old jar survives"
assert_eq "1.21.3" "$(cat "$SERVER_DIR/.minecraft-version")" "and so does its recorded version"
assert_contains "$OUT" "keeping the jar already installed" "it should say what it fell back to"
teardown

setup "an empty download is rejected rather than installed" 'MINECRAFT_VERSION="1.21.4"'
seed_jar "1.21.3"
STUB_JAR_EMPTY=1 run_script update-server-jar.sh
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "a zero-byte jar must not replace a working one"
assert_eq "1.21.3" "$(cat "$SERVER_DIR/.minecraft-version")" "recorded version unchanged"
teardown

setup "an unreachable Fabric meta leaves everything alone" 'MINECRAFT_VERSION="1.21.4"'
seed_jar "1.21.3"
STUB_FABRIC_META_FAIL=1 run_script update-server-jar.sh
assert_eq "0" "$RC" "exit code"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar survives"
teardown

setup "a failed pre-upgrade backup cancels the upgrade" \
  'MINECRAFT_VERSION="1.21.4"' 'BACKUP_BUCKET=""'
# An upgrade with no way back is worse than staying a version behind.
seed_jar "1.21.3"
mkdir -p "$SERVER_DIR/world"
# A plain file where the backup directory belongs: mkdir -p fails, so
# backup.sh exits non-zero exactly as it would on a full or read-only volume.
rm -rf "$DATA_MOUNT/backups"
printf 'not a directory' > "$DATA_MOUNT/backups"
run_script update-server-jar.sh
assert_eq "0" "$RC" "exit code"
assert_contains "$OUT" "refusing to upgrade" "it should refuse explicitly"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar must be untouched"
assert_eq "1.21.3" "$(cat "$SERVER_DIR/.minecraft-version")" "recorded version unchanged"
teardown

setup "a fresh world is upgraded without demanding a backup" 'MINECRAFT_VERSION="1.21.4"'
# No world directory yet means nothing to lose, so a missing backup path is
# not a reason to block the upgrade.
seed_jar "1.21.3"
run_script update-server-jar.sh
assert_eq "stub-fabric-jar-body" "$(cat "$SERVER_DIR/server.jar")" "jar replaced"
teardown

setup "server_jar_url takes the jar out of this script's hands" \
  'MINECRAFT_VERSION="1.21.4"' 'SERVER_JAR_URL="https://example.com/custom.jar"'
seed_jar "1.21.3"
run_script update-server-jar.sh
assert_contains "$OUT" "leaving the jar alone" "it should decline"
assert_no_file "$STUB_DIR/jar-downloads" "no download"
teardown

setup "a recorded version with trailing whitespace is not a version change" \
  'MINECRAFT_VERSION="1.21.4"'
# The file is written with a trailing newline; an unstripped compare would
# reinstall the same jar on every single boot.
printf 'old-jar-body' > "$SERVER_DIR/server.jar"
printf '1.21.4  \r\n' > "$SERVER_DIR/.minecraft-version"
run_script update-server-jar.sh
assert_no_file "$STUB_DIR/jar-downloads" "no download"
assert_eq "old-jar-body" "$(cat "$SERVER_DIR/server.jar")" "the jar must be untouched"
teardown

setup "an upgrade announces itself in Discord" \
  'MINECRAFT_VERSION="1.21.4"' 'DISCORD_WEBHOOK_SSM_PARAM="/minecraft/discord-webhook-url"'
printf 'https://discord.com/api/webhooks/1/abc' > "$STUB_SSM_DIR/_minecraft_discord-webhook-url"
seed_jar "1.21.3"
run_script update-server-jar.sh
posts=$(cat "$STUB_DIR/webhook-posts" 2>/dev/null || echo "")
assert_contains "$posts" "1.21.3 to 1.21.4" "players should be told the version moved"
teardown

setup "a failed upgrade also says so in Discord" \
  'MINECRAFT_VERSION="1.21.4"' 'DISCORD_WEBHOOK_SSM_PARAM="/minecraft/discord-webhook-url"'
printf 'https://discord.com/api/webhooks/1/abc' > "$STUB_SSM_DIR/_minecraft_discord-webhook-url"
seed_jar "1.21.3"
STUB_JAR_FAIL=1 run_script update-server-jar.sh
posts=$(cat "$STUB_DIR/webhook-posts" 2>/dev/null || echo "")
assert_contains "$posts" "failed" "a silent failure would look like a successful upgrade"
assert_contains "$posts" "1.21.3" "and it should name what is actually running"
teardown

# ==========================================================================

printf '\n----------------------------------------\n'
printf 'shell tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
