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

Fabric mods are jars in `/srv/minecraft/server/mods`:

```bash
sudo mc maintenance-stop
sudo mkdir -p /srv/minecraft/server/mods
sudo curl -L -o /srv/minecraft/server/mods/lithium.jar '<url>'
sudo chown -R minecraft:minecraft /srv/minecraft/server/mods
sudo mc start
sudo mc logs -f
```

Server-side performance mods (Lithium, FerriumMC) are usually worth it on a
small instance. Mods requiring a matching client install must be distributed to
players separately.

Give the instance more memory if you add a large modpack: raise `instance_type`
to `t4g.large` and apply. The heap is sized from instance memory automatically
unless you set `java_heap_mb`.

## Upgrading Minecraft

```hcl
minecraft_version = "1.21.4"
```

`terraform apply` publishes the new value, but the jar is only downloaded when
one is not already present. To force it:

```bash
sudo mc maintenance-stop
sudo rm /srv/minecraft/server/server.jar
sudo /opt/minecraft/bin/bootstrap.sh
```

**Back up first.** A world opened by a newer version cannot be opened by the old
one again.

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
