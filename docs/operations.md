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

`on-stop.sh` runs afterwards, takes a backup, and powers the instance off **only
if that sentinel file is there**. That is the difference between a finished
session and an admin stopping the service to work on something:

- `mc stop` and `/stop` in Discord write the sentinel → instance powers off
- `mc maintenance-stop` and plain `systemctl stop minecraft` do not → instance
  stays up

`instance_initiated_shutdown_behavior` is `stop`, not `terminate`, so
`shutdown -h` stops the instance and leaves both volumes intact.

## Backups

A backup runs automatically on every clean stop. It tars the server directory,
skipping logs, crash reports and the redownloadable Fabric libraries, and
uploads it to `s3://<bucket>/backups/minecraft-<timestamp>.tar.gz`.

The most recent `local_backup_keep` (default 3) also stay on the data volume at
`/srv/minecraft/backups`. S3 expires objects after `backup_retention_days`
(default 30).

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

- `idle_timeout_minutes` — the main one
- `shutdown_on_crash = true` (the default) — a crash loop cannot idle for hours
- `max_uptime_hours` — a hard cap on a single session, off by default
- An AWS Budgets alert on the account

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
