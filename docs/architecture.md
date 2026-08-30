# Architecture

## The loop

```
                     ┌──────────────────────────────────────────┐
                     │ Discord                                  │
                     │   /start  ──────────────┐                │
                     │   webhook messages ◀──┐ │                │
                     └───────────────────────┼─┼────────────────┘
                                             │ │ signed POST
                                             │ ▼
                     ┌───────────────────────┼──────────────────┐
                     │ Lambda                │                  │
                     │   (function URL, or an HTTP API)         │
                     │   verify Ed25519 signature               │
                     │   describe / start instance              │
                     │   SendCommand for a graceful stop        │
                     └───────────────────────┼──────────────────┘
                                             │ ec2:StartInstances
                                             ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ EC2 instance (stopped between sessions)                      │
   │                                                              │
   │  minecraft-refresh.service   config from SSM, scripts from S3│
   │            ↓                                                 │
   │  minecraft.service                                           │
   │    ExecStartPre  announce-address.sh   publish the address   │
   │                  seed-players.sh       ops / whitelist       │
   │                  update-server-jar.sh  match minecraft_version│
   │                  install-mods.js       match server_mods     │
   │    ExecStart     servermanager.js  ──► java -jar server.jar  │
   │                     watches the log, counts players          │
   │    ExecStopPost  on-stop.sh   backup to S3, then shutdown -h │
   └──────────────────────────────────────────────────────────────┘
```

The instance is never terminated, only stopped. Its EBS volumes persist, so a
restart is a boot, not a rebuild.

## Why each piece is the way it is

### The Lambda has no dependencies

Discord signs every interaction with Ed25519 and requires a `401` for bad
signatures. The obvious library is PyNaCl, but it ships a compiled C extension,
which means either vendoring a manylinux wheel or maintaining a Lambda layer —
which is why the original had 19 MB of `boto3` committed to the repository.

`lambda/ed25519_verify.py` implements verification in pure Python instead, about
120 lines against RFC 8032. `boto3` is already in the Lambda runtime. So
Terraform can zip `lambda/` directly with `archive_file` — no build step, no
layer, nothing to keep in sync.

Verification costs roughly 30 ms, against Discord's 3 second budget. Correctness
is pinned by the RFC 8032 test vectors in `tests/test_ed25519_verify.py`.

### One Lambda, not two

The original used a second Lambda invoked asynchronously, to answer Discord
inside three seconds while the slow work happened elsewhere. It turns out
nothing here is slow: `DescribeInstances` and `StartInstances` are both
sub-second, and `StartInstances` returns as soon as the state change is
recorded, not when the instance is up. One function, one round trip.

### Configuration comes from SSM, not user-data

cloud-init runs user-data once, at first boot. If the configuration lived only
there, changing the idle timeout would mean rebuilding the instance — and
rebuilding is exactly what you do not want to do to a machine holding a world.

Instead Terraform publishes the whole configuration to a single SSM parameter,
and `minecraft-refresh.service` re-reads it on every boot, ordered before
`minecraft.service`. The same service re-downloads `server/` from S3. A
`terraform apply` followed by a stop and start puts any change live, with no
replacement.

The refresh is deliberately failure-tolerant: if AWS is unreachable, the copies
already on disk are kept and the server still starts.

### Idle detection reads the log

Alternatives were querying the server over RCON, or the Server List Ping
protocol. Both need a port open and a credential managed. Reading `joined the
game` / `left the game` out of stdout needs neither, and the manager is already
holding that pipe.

The patterns are anchored to the `]: ` that ends the log prefix and to
end-of-line, so a player typing "someone joined the game" in chat cannot forge a
join — chat lines read `]: <Name> message` and fail the anchor.

Lines are read through `readline` rather than by testing raw chunks. stdout
arrives in arbitrary pieces, and a chunk boundary landing mid-line silently
drops the event — a bug the original had.

The cost of reading the log rather than asking the server is that a name the
patterns do not match is a player the server does not know about. Usernames are
at most 16 characters of `[A-Za-z0-9_]`, which is exact for Java Edition; a
proxy that rewrites join lines, or a Bedrock bridge that prefixes names, would
not be counted and the server would idle out from under them.
`discord_notify_player_events` makes that visible, since it posts exactly what
the counter saw and nothing else.

### The boot reconciles, it does not install

`bootstrap.sh` runs once, from cloud-init, and never again. Anything that only
happened there would be frozen at whatever it was on the day the instance was
created -- so a setting changed months later would appear to do nothing, with
no error to explain it.

Everything that can drift is therefore reconciled on **every** boot, before the
server starts, by an `ExecStartPre` that compares desired against actual:

| Script | Reconciles | Skips when |
| --- | --- | --- |
| `seed-players.sh` | `ops.json`, `whitelist.json` | the file exists — in-game `/op` owns it from then on |
| `update-server-jar.sh` | the jar against `minecraft_version` | versions already match, or it is `latest` |
| `install-mods.js` | `mods/` against `server_mods` | each jar is present and its checksum matches |

The order matters: the jar is settled before the mods are resolved, so a mod is
never resolved against a Minecraft version other than the one about to run.

None of the three may fail the boot. Each is invoked with a `-` prefix and
returns 0 whatever happens, because every one of them is an improvement to a
server that would otherwise still work. A missing optimisation is a bad
evening; a server that will not start is a bad week, on a box whose only way in
is SSM.

### A sentinel file decides whether to power off

`on-stop.sh` runs as `ExecStopPost`, so it fires however the service ends. It
powers the instance off only when `/run/minecraft/idle-shutdown` exists.

That single file separates "the session finished" from "an admin stopped the
service". An idle shutdown or a `/stop` writes it; `systemctl stop minecraft`
does not, so maintenance never turns into an unexpected power-off. `/run` is
tmpfs, so it clears itself every boot.

### Nothing is left billing after a failure

The sentinel above answers "was this stop intended". It does not answer "did the
thing fail before it could write one", and every such gap is an instance that
runs until somebody notices the bill.

They fail in different places, so each is closed separately:

- **The server crashes.** `servermanager.js` writes the sentinel itself on an
  unexpected exit.
- **The server process cannot be started at all** — a missing or unreadable
  `JAVA_BIN`, a package install that did not take. Node reports that as an
  `error` event and *never* an `exit`, so the teardown has to be reachable from
  both events rather than hung off `exit` alone. Otherwise the manager sits
  holding the console FIFO open, the unit stays `active`, `ExecStopPost` never
  runs, and nothing at all powers the instance off.
- **The server starts but never finishes starting** — a mod hanging in init, a
  world that will not load, a JVM thrashing on a small instance. The ready line
  is the only thing that arms the idle countdown, so there would be no
  countdown running to catch it. A startup watchdog fires after 30 minutes
  (`STARTUP_TIMEOUT_MINUTES`) and takes the same path an idle shutdown does.
- **The unit fails to start**, typically because the address could not be
  published: `on-stop.sh` reads systemd's `$SERVICE_RESULT` and powers off when
  it is anything but `success`.
- **The very first boot fails**, before `minecraft.service` exists at all. An
  `EXIT` trap in user-data schedules `shutdown -h +30`, capping the cost while
  leaving a window to connect and read the log. The trap covers the whole
  script rather than only the `bootstrap.sh` call, because the likelier
  failures — a `dnf` mirror, an instance role that has not finished propagating
  — happen above it, and `set -e` would otherwise exit before the guard.
- **The power-off is outrun by its own backup.** `on-stop.sh` backs the world
  up before it calls `shutdown`, and systemd kills the entire stop sequence at
  `TimeoutStopSec`. An unbounded tar, gzip and S3 upload of a world that grows
  every session would eventually take the power-off with it, so the backup runs
  under a `timeout` well inside that budget. A backup that cannot finish is
  worth losing; the session it would otherwise cost is not.

The crash, failed-spawn, failed-unit and first-boot paths are all governed by
`shutdown_on_crash`, so one setting turns them off together while debugging. The
startup watchdog follows `idle_timeout_minutes` instead — it is an idle
shutdown that happens to fire before anybody could join — so setting that to `0`
disables it along with the rest of the idle behaviour.

None of this bounds a session with somebody actually connected: the idle
countdown correctly will not fire while a player is online, however long they
stay. `max_uptime_hours` ends such a session outright and is off by default;
`uptime_warning_enabled` says so in Discord without ending anything.

### Configuration is parsed, not sourced

`config.env` is read by two different consumers: systemd, as an
`EnvironmentFile` for the unit, and the shell scripts. Sourcing it in bash would
have been one line, but it expands `$`, backticks and backslashes inside the
values -- so a server MOTD containing a dollar sign breaks quietly, and one
containing `$(...)` executes as root at boot.

`load_env_file` in `common.sh` parses the file with parameter expansion only,
unescaping exactly what systemd unescapes: one layer of surrounding quotes, then
`\` and `\"`. Terraform escapes in the mirror-image order and flattens
newlines, which would otherwise split one setting across two lines. The round
trip is tested against values containing quotes, backslashes, dollar signs,
backticks and non-ASCII text.

### Two volumes

Code lives on the root volume under `/opt/minecraft`. The world lives on a
separate EBS volume mounted at `/srv/minecraft`.

Keeping them apart means the instance can be replaced — a new AMI, a different
instance type — without touching the world, and the world can be snapshotted on
its own. They must not overlap: mounting the data volume over the payload
directory would hide the scripts that mounted it.

The volume is found by its `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*`
symlink, because Nitro instances rename EBS devices unpredictably. `nofail` in
fstab keeps a missing volume from wedging boot into emergency mode, where there
would be no SSM agent to recover through.

### `/stop` runs a script on the instance

The Lambda has no `ec2:StopInstances` permission, deliberately. Stopping an
instance under a running Minecraft server risks a half-written region file.

Instead `/stop` uses `ssm:SendCommand` to run `request-stop.sh`, which writes
the sentinel and stops the service. The server saves the world itself as it
shuts down, `on-stop.sh` archives it, and only then does the instance power off.
There is no path through this system that skips the save. The *backup* can be
cut short — it runs under a timeout, because missing the power-off costs more
than missing one archive — but the save is the server's own clean stop and is
not optional.

### The Java process runs unprivileged

The systemd unit runs as root so `ExecStopPost` can call `shutdown` without a
sudoers rule. `servermanager.js` drops to the `minecraft` user when spawning
Java, which is the process actually exposed to the internet. That gets the
security benefit without the privilege plumbing.

## Permissions

**Instance role**

| Permission                          | Scope                              |
| ----------------------------------- | ---------------------------------- |
| `AmazonSSMManagedInstanceCore`      | managed policy; shell + RunCommand |
| `ssm:GetParameter`                  | `/<project>/*` only                |
| `s3:GetObject`                      | the payload object only            |
| `s3:PutObject`, `GetObject`, `ListBucket` | the `backups/` prefix        |
| `route53:ChangeResourceRecordSets`  | one zone, one record name, type A  |

**Lambda role**

| Permission              | Scope                                          |
| ----------------------- | ---------------------------------------------- |
| `ec2:DescribeInstances` | `*` — the API has no resource-level permissions |
| `ec2:StartInstances`    | the one instance                                |
| `ssm:SendCommand`       | the one instance, `AWS-RunShellScript` only     |
| logs                    | its own log group                               |

`ssm:SendCommand` is withheld entirely when `allow_stop_command = false`, so a
deployment where nobody may end a session cannot have one ended by a bug in the
handler either.

The endpoint is public because Discord calls it with no AWS credentials: a
function URL with `AUTHORIZATION_NONE`, or an API Gateway HTTP API when
`endpoint_type = "api_gateway"`. Either way every request is authenticated by
its Ed25519 signature before anything else happens, and unsigned requests get a
`401` without reaching the command handlers.

The two are interchangeable because API Gateway's 2.0 payload format hands the
Lambda the same lowercase headers, `body` and `isBase64Encoded` a function URL
does, so neither is a special case in the handler.

## What is not here

- **No auto-scaling or multi-server support.** One instance, one world. Run a
  second stack with a different `project_name` if you need two.
- **No RCON.** `mc console` writes to a FIFO the manager forwards to stdin,
  which is enough for admin commands and needs no port or password.
- **No player-facing web UI.** Discord is the interface.
- **No mod dependency resolution.** `server_mods` installs what you list; if a
  mod needs the Fabric API, list that too.
- **No EBS snapshots.** Backups are tarballs in S3, which are portable and easy
  to inspect. Add a DLM policy on the data volume if you want block-level
  snapshots too.
