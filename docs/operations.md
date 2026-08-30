# Operations

## Getting a shell

No SSH key, no open port. Session Manager tunnels a shell through the AWS API:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo -i
```

The instance must be running. Start it with `/start` in Discord, or:

```bash
aws ec2 start-instances --instance-ids $(terraform -chdir=terraform output -raw instance_id)
```

If `start-session` complains about a missing plugin, install the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

## The `mc` command

```
mc status              service state, connect address
mc address             just the address
mc console <command>   run a server command, e.g. mc console list
mc logs -f             follow the server log
mc backup              back up now, safe while players are online
mc stop                save, back up, power off
mc maintenance-stop    stop the server but keep the instance running
mc start               start the server
mc update              re-download the scripts Terraform uploaded
```

`mc console` writes to a FIFO the server manager forwards to the server's stdin,
so the reply shows up in `mc logs`, not in your terminal:

```bash
mc console list
mc logs | tail -5
```

## How the shutdown decision is made

`servermanager.js` counts players from `joined the game` / `left the game` lines
in the server log. When the count reaches zero it starts a timer for
`idle_timeout_minutes`; if nobody joins before it fires, it sends `stop` to the
server console and writes `/run/minecraft/idle-shutdown`.

Two other things write the same sentinel, because the countdown above cannot
catch them: an unexpected exit of the server process (governed by
`shutdown_on_crash`), and a server that never finishes starting at all, which
never reaches the ready line and so never starts a countdown to begin with.
That last one gives up after 30 minutes.

`on-stop.sh` runs afterwards, takes a backup, and powers the instance off **only
if that sentinel file is there**. That is the difference between a finished
session and an admin stopping the service to work on something:

- `mc stop` and `/stop` in Discord write the sentinel → instance powers off
- an idle timeout, a crash, or a start that never completed → instance powers off
- `mc maintenance-stop` and plain `systemctl stop minecraft` do not → instance
  stays up

The backup runs under a timeout (`STOP_BACKUP_TIMEOUT_SECONDS`, 180s by
default). systemd kills the whole stop sequence at `TimeoutStopSec`, so a backup
big enough to overrun it would take the power-off with it and leave the instance
up with nothing running on it. A cut-short backup is logged and the shutdown
proceeds.

`instance_initiated_shutdown_behavior` is `stop`, not `terminate`, so
`shutdown -h` stops the instance and leaves both volumes intact.

## Backups

A backup runs automatically on every clean stop. It tars the server directory,
skipping logs, crash reports and the redownloadable Fabric libraries, and
uploads it to `s3://<bucket>/backups/minecraft-<timestamp>.tar.gz`.

The most recent `local_backup_keep` (default 3) also stay on the data volume at
`/srv/minecraft/backups`. S3 expires objects after `backup_retention_days`
(default 30); setting that to `0` removes the expiry rule altogether rather than
setting a long one, so archives then accumulate indefinitely.

The stop-time backup runs under a timeout — 180 seconds by default — because
systemd kills the whole stop sequence at `TimeoutStopSec` and the power-off
comes after the backup. A world large enough to overrun it is backed up
partially, logged, and the instance still stops. If you see
`backup failed or exceeded 180s` in the journal, take backups by hand with
`sudo mc backup`, which has no such deadline.

List them:

```bash
aws s3 ls s3://$(terraform -chdir=terraform output -raw backup_bucket)/backups/
```

Take one by hand — safe while people are playing, because it pauses world saving
for the duration:

```bash
sudo mc backup
```

### Restoring

On the instance, with the server stopped:

```bash
sudo mc maintenance-stop
cd /srv/minecraft
sudo mv server server.broken
sudo mkdir server
aws s3 cp s3://<bucket>/backups/minecraft-<timestamp>.tar.gz - | sudo tar -xz -C server
sudo chown -R minecraft:minecraft server
sudo mc start
```

Keep `server.broken` until you have confirmed the restore is good.

### Migrating an existing world in

Upload a tarball of your current server directory (with `world/` at its root),
then point Terraform at it:

```bash
tar -czf old-server.tar.gz -C /path/to/old/server .
aws s3 cp old-server.tar.gz s3://your-bucket/old-server.tar.gz
```

```hcl
restore_from_s3 = "s3://your-bucket/old-server.tar.gz"
```

It is unpacked once, during the first boot, and only when no world is present.
It has no effect on a server that already has one.

## Changing settings

Edit `terraform/terraform.tfvars`, then:

```bash
terraform -chdir=terraform apply
```

The instance is **not** rebuilt. Terraform writes the configuration to SSM
Parameter Store, and `minecraft-refresh.service` re-reads it on every boot,
before the server starts. So:

1. `terraform apply`
2. `/stop` in Discord (or wait for the idle timeout)
3. `/start`

The change is live. The same path carries script changes: anything you edit
under `server/` is re-zipped, uploaded and picked up on the next boot, or
immediately with `sudo mc update && sudo systemctl restart minecraft`.

Two settings are exceptions and need an instance rebuild, because they are baked
in at first boot: `instance_type` (Terraform handles the replacement itself) and
anything already written into `server.properties`, which is only created when
absent. To change the latter, edit `/srv/minecraft/server/server.properties`
directly, or delete it and restart to have it regenerated from the Terraform
values.

For what else can be edited on the instance directly, and what gets reverted the
next time it starts, see [making changes by hand](#making-changes-by-hand).

## Making changes by hand

Sometimes the right move is to edit something on the instance directly — a
`server.properties` value with no Terraform variable, a mod that is not on
Modrinth, a plugin config, a one-off experiment. Most of that is fine and
survives indefinitely. Some of it is reverted the next time the server starts,
and the difference is not obvious from looking at the filesystem.

The rule behind all of it: **the instance reconciles itself against Terraform on
every start.** Anything Terraform is the source of truth for gets rewritten from
Terraform. Anything Terraform does not know about is left alone forever.

### What gets overwritten

Every one of these is restored from S3 or SSM on each boot — and, because
`minecraft.service` has `Wants=minecraft-refresh.service`, on each
`systemctl restart minecraft` as well. Editing them in place gets you a change
that works right up until the next `/stop` and `/start`, which is the worst
possible way to find out.

| Path | Rewritten by | From |
| --- | --- | --- |
| `/etc/minecraft/config.env` | `refresh-config.sh` | the SSM parameter Terraform publishes |
| `/opt/minecraft/bin/*` | `update-payload.sh` | `server/` in the repo, via S3 |
| `/opt/minecraft/payload/` | `update-payload.sh` | deleted and re-extracted wholesale |
| `/usr/local/bin/mc` | `update-payload.sh` | the same payload |
| `/etc/systemd/system/minecraft.service`, `minecraft-refresh.service` | `update-payload.sh` | `server/systemd/` in the repo |
| `mods/` jars listed in `mods/.managed.json` | `install-mods.js` | `server_mods` |
| `server.jar`, `.minecraft-version` | `update-server-jar.sh` | `minecraft_version`, on a change |

To change any of these, change them at the source and apply:

```bash
terraform apply                                    # publishes config and scripts
sudo mc update && sudo systemctl restart minecraft # or just /stop and /start
```

### What survives

Nothing reconciles these, so an edit sticks until you change it back. This is
where hand changes belong.

| Path | Why it survives |
| --- | --- |
| `/srv/minecraft/server/server.properties` | written only when absent, and only on the first boot |
| `/srv/minecraft/server/ops.json`, `whitelist.json` | `seed-players.sh` writes them only when absent, so in-game `/op` wins |
| `/srv/minecraft/server/world/` and the rest of the world | never touched by anything here |
| `mods/` jars **not** in `.managed.json` | `install-mods.js` only ever touches jars it installed |
| `/srv/minecraft/backups/` | rotated by count; existing archives are never rewritten |
| anything else under `/srv/minecraft` | the data volume is yours |

So: to add a mod that is not on Modrinth, drop the jar into
`/srv/minecraft/server/mods/` and leave it out of `server_mods`. To change a
`server.properties` setting, edit the file. Neither needs anything from
Terraform, and neither will be undone.

### Two levels of "survives"

They are not the same thing, and the difference costs a world if you get it
wrong.

**Across a stop/start and a reboot:** everything above, plus anything you
install on the root volume — `dnf install`ed packages, files in `/root`, a cron
job. Stopping an EC2 instance keeps both volumes.

**Across an instance replacement:** only `/srv/minecraft`. The root volume is
built fresh from the AMI and `bootstrap.sh`, so root-volume changes are gone.
Terraform replaces the instance when `instance_type` changes, and if you ever
taint or `-replace` it. `terraform destroy` takes the data volume too.

If a root-volume change needs to outlive a replacement, it has to be in the
repo — a script under `server/bin/` invoked from a systemd unit, or a step in
`bootstrap.sh`. That is the only mechanism that reruns on a fresh instance.

### Overriding a setting on one instance, temporarily

Occasionally you want a value on *this* box that differs from what Terraform
publishes — a longer idle timeout while you watch something, a bigger heap for
one session. Editing `config.env` does not hold on its own, because starting
the server pulls in `minecraft-refresh.service` and that rewrites the file
before the server reads it.

There is no drop-in trick for this. A `.d/override.conf` with `Environment=`
looks like it should work and does not: systemd gives `EnvironmentFile=` —
which is how `config.env` is loaded — precedence over `Environment=`, whatever
order they appear in ([systemd#9788](https://github.com/systemd/systemd/issues/9788)).

What does work is stopping the refresh from running while you experiment:

```bash
sudo systemctl mask minecraft-refresh.service    # the refresh cannot start now
sudo nano /etc/minecraft/config.env              # edit freely
sudo systemctl restart minecraft                 # starts without being reverted
```

`Wants=` is a soft dependency, so `minecraft.service` starts normally with the
refresh masked, and nothing rewrites `config.env` or `/opt/minecraft/bin` until
you undo it:

```bash
sudo systemctl unmask minecraft-refresh.service
sudo systemctl restart minecraft                 # back to what Terraform says
```

Leave it masked and the instance stops tracking Terraform entirely — no config
changes, no script updates, on any boot. That is a debugging state, not a
configuration: treat the mask as something you are holding, not something you
set.

A difference you want permanently belongs in `terraform.tfvars`, where the next
person to read the config can see it. That is the whole point of the
reconciliation — an instance that has quietly drifted from its configuration is
the thing this design is built to prevent.

> Be careful raising `IDLE_TIMEOUT_MINUTES`, and more careful setting it to `0`.
> That is the switch that stops the instance powering itself off, and a masked
> refresh unit is exactly the kind of thing left behind after a debugging
> session. If you do it, `uptime_warning_enabled = true` will tell you when you
> have forgotten.

### Checking that a change stuck

The honest test is a full cycle, because a restart is what reverts things:

```bash
sudo mc stop        # or /stop in Discord
# /start in Discord, then:
sudo mc status
```

To see what the instance currently believes:

```bash
sudo cat /etc/minecraft/config.env        # the settings, as refreshed from SSM
sudo mc mods                              # which jars are managed and which are yours
systemctl cat minecraft                   # the unit plus any drop-ins in effect
```

## Mods

Mods are managed from Terraform. `server_mods` is a list, and the instance
reconciles `/srv/minecraft/server/mods` against it on every boot: entries you
add are downloaded, entries you remove are deleted, and a Minecraft version
change re-resolves all of them.

```hcl
server_mods = ["lithium", "ferrite-core", "krypton", "spark"]
```

```bash
terraform apply                 # publishes the list
```

then `/stop` and `/start` in Discord. To apply it without waiting for a boot:

```bash
sudo mc mods sync               # download and prune now
sudo systemctl restart minecraft
sudo mc mods                    # what is installed, and which entries are managed
```

Fabric reads the mods directory once, at launch, so a sync always needs a
restart to take effect. Failures never block the server from starting; they are
logged under `[mods]`:

```bash
sudo journalctl -u minecraft | grep '\[mods\]'
```

Entries are Modrinth project slugs, a slug pinned to one build
(`lithium@0.15.0`), or an `https://` URL ending in `.jar`. Jars you copy in by
hand are never touched.

**[docs/mods.md](mods.md) is the full guide** — which mods are worth adding,
what players need installed, editing mod and server configuration, tuning for
more players, and upgrading Minecraft without breaking your mods.

## Upgrading Minecraft

Set the version and apply:

```hcl
minecraft_version = "1.21.4"      # from "latest", or from an older pin
```

```bash
terraform apply
```

Then `/stop` and `/start`. On the next boot `update-server-jar.sh` sees that
the installed version no longer matches the configured one, **backs the world
up**, downloads the new Fabric launcher and re-resolves every mod against the
new version.

`sudo mc version` shows both numbers, so you can check which one you are on:

```
installed:  1.21.3
configured: 1.21.4
```

**`latest` never upgrades on its own.** It is resolved once, when the jar is
first installed, and then stays put. Following it automatically would upgrade
your world the first time Mojang shipped a release — with no backup anyone
intended, no check that your mods have builds for it, and no way back. Pin a
version to move.

**Worlds do not downgrade.** A world opened by a newer Minecraft cannot be
opened by the older one again; the pre-upgrade backup is the only way back. See
[Restoring](#restoring).

If the upgrade cannot be completed — the backup fails, the download fails,
Fabric has no build for that version — the old jar stays in place and the
server starts on the version it was already running, saying so in the journal
and in Discord. A failed upgrade costs you a version, not an evening.

To upgrade on the spot rather than at the next boot, or to move a server whose
`minecraft_version` is `latest`:

```bash
sudo mc maintenance-stop
sudo mc upgrade --yes
sudo mc start && sudo mc logs -f
```

## Whitelisting and moderation

`allowed_cidrs` defaults to the whole internet, so anyone who learns the
address can try to join. Mojang authentication proves who somebody is; it does
not prove they were invited. A whitelist does.

```hcl
server_whitelist         = true
server_whitelist_players = ["YourMinecraftName", "AFriend"]
server_ops               = ["YourMinecraftName"]
```

`terraform apply`, then `/stop` and `/start`.

Turning the whitelist on with nobody listed is refused at plan time rather than
producing a server nobody can enter -- including you.

### Then do the rest in game

`server_ops` is the setting that means you do not have to come back here. An
operator has the moderation commands in the chat box:

| In game | What it does |
| --- | --- |
| `/whitelist add <player>` | let somebody in |
| `/whitelist remove <player>` | stop letting them in |
| `/whitelist list` | who is allowed |
| `/kick <player> [reason]` | end this session |
| `/ban <player> [reason]` | and every future one |
| `/pardon <player>` | undo a ban |
| `/op <player>` | make somebody else a moderator |

So the Terraform lists only have to get the first person in. Everything after
that happens at the time it comes up, by whoever is online, with no apply and
no shell.

Without an in-game operator you would be editing `whitelist.json` over SSM
every time a friend wanted to join, which is the kind of chore that ends with
the whitelist being turned off.

### How the two settings interact

Both lists are **seeded, not enforced**. On any boot where `ops.json` or
`whitelist.json` does not exist, it is written from the Terraform value. Once
the file exists it is never touched again.

That means:

- Adding `server_ops` after the first deploy still works -- the file did not
  exist, so the next boot creates it. This is not bootstrap-only.
- An `/op` granted in game at 2am survives every later restart. Terraform will
  not quietly revoke it.
- Changing the Terraform value after the file exists does **nothing**. Use the
  in-game commands, or delete the file and restart to re-seed from config:

  ```bash
  sudo mc maintenance-stop
  sudo rm /srv/minecraft/server/whitelist.json
  sudo mc start
  ```

### If you lock yourself out

Being off your own whitelist is recoverable -- the server console is not
subject to it:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo mc console "whitelist add YourMinecraftName"
sudo mc console "op YourMinecraftName"
sudo mc logs                      # the reply appears here
```

`mc console` runs a command as the server console, which outranks any operator.

## Knowing when it stops

By default the server shuts itself down silently. Set `discord_webhook_url` and
it posts "Server stopped due to inactivity." to a channel, along with crash and
failed-start messages that are otherwise easy to miss for days. One minute to
set up: [notifications.md](notifications.md).

## Watching costs

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '30 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Tags":{"Key":"Project","Values":["minecraft"]}}'
```

Every resource is tagged `Project = <project_name>`, so this covers the whole
stack. Cost Explorer needs cost allocation tags activated once, in Billing →
Cost Allocation Tags.

Guards against a runaway bill, in order of usefulness:

- `idle_timeout_minutes` — the main one, and the only one that runs by default
- `shutdown_on_crash = true` (the default) — a crash loop cannot idle for hours
- `uptime_warning_enabled` — posts to Discord when a session has been running
  for `uptime_warning_hours`, and again every interval after that. It ends
  nothing, which is what makes it safe to turn on: the idle timeout only ever
  fires on an *empty* server, so this is what covers the case it cannot — one
  player still connected, hours after everyone stopped paying attention. It is
  also the only thing that tells you the idle shutdown itself has failed, since
  a warning saying nobody is online means exactly that
- `max_uptime_hours` — a hard cap that ends the session outright, off by
  default. Real protection, but it disconnects whoever is playing when it
  fires, so pick a number you would be happy to be kicked at
- An AWS Budgets alert on the account — the backstop that works even when the
  instance is the thing that is broken

## Tearing it down

```bash
terraform -chdir=terraform destroy
```

This deletes the instance **and the data volume with the world on it**. Take a
backup and copy it somewhere else first:

```bash
aws s3 cp s3://<bucket>/backups/<newest>.tar.gz ./
```

The bucket refuses to be deleted while it still holds backups unless you set
`force_destroy_buckets = true`, which is deliberate.
