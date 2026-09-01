# Applying changes

What you have to do to make a setting actually take effect. Most of the time it
is the same three steps; the exceptions are the point of this page.

## The general case

```bash
terraform apply        # publish the new configuration
```

then, in Discord:

```
/stop                  # or wait for the idle timeout
/start
```

That is it. The change is live on the next boot.

Terraform does not touch the running instance. It writes every setting to one
SSM parameter, and `minecraft-refresh.service` re-reads that parameter — and
re-downloads the scripts from S3 — on every boot, before the server starts. So
a stop and a start is what applies a change, and nothing is rebuilt.

If the server is already stopped, `terraform apply` is enough on its own; the
next `/start` picks it up.

## Getting to the instance

Several of the exceptions below are fixed by changing something on the instance
itself. That does **not** mean SSH — port 22 is closed by default and there is
no key to manage. Everything goes through SSM Session Manager, over the AWS API,
with the credentials you already use for Terraform:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo mc status
```

The instance has to be running, so `/start` first. Two things that catch people
the first time: `start-session` needs the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
which installs separately from the AWS CLI, and every `aws` command needs a
region -- `terraform -chdir=terraform output -raw shell_command` prints this one
with the region already filled in.

If you would rather not open a session at all, run the one command directly and
read its output afterwards:

```bash
id=$(aws ssm send-command \
  --instance-ids $(terraform -chdir=terraform output -raw instance_id) \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sed -i s/^motd=.*/motd=hello/ /srv/minecraft/server/server.properties"]' \
  --query 'Command.CommandId' --output text)

aws ssm get-command-invocation \
  --command-id "$id" \
  --instance-id $(terraform -chdir=terraform output -raw instance_id) \
  --query 'StandardOutputContent' --output text
```

That is the same mechanism `/stop` uses. It needs no session, no port and no
key — just an instance that is running.

## "I added someone to the whitelist"

This is the most common exception, so it goes first: **`terraform apply` will
not do it.** Add them in game or from the instance instead.

From in game, as an operator:

```
/whitelist add SomePlayer
```

Or from a shell on the instance, with the server running:

```bash
sudo mc console whitelist add SomePlayer
sudo mc console whitelist list
```

`server_whitelist_players` seeds `whitelist.json` **only when that file does not
already exist**. Once it does, the file belongs to the in-game `/whitelist`
command and the Terraform value is ignored — deliberately, so that somebody you
added at 2am is not silently removed by the next reboot. The same is true of
`server_ops` and `ops.json`.

The seeding runs on *every* boot, not just the first, so if neither file exists
yet the value is still picked up. That is worth checking before assuming:

```bash
sudo ls -l /srv/minecraft/server/ops.json /srv/minecraft/server/whitelist.json
```

If the file is there, use the in-game command. If it is not, `terraform apply`
plus a restart will seed it.

If you would rather go back to the Terraform list as the source of truth, delete
the file and restart; it is regenerated from the current value:

```bash
sudo mc maintenance-stop
sudo rm /srv/minecraft/server/whitelist.json
sudo mc start
```

That discards every name added in game, so it is the wrong move on a server
people have been using.

## Every setting, by what it needs

### `terraform apply` alone — no restart

These live in the Lambda or in AWS resources, not on the instance.

| Setting | Notes |
| --- | --- |
| `discord_public_key`, `discord_allowed_role_ids`, `discord_stop_role_ids` | Lambda environment; live the moment the apply finishes |
| `allow_stop_command` | Lambda environment *and* the IAM policy that carries the command |
| `endpoint_type` | Builds the other endpoint. **The URL changes**, so paste the new one into the Discord developer portal |
| `allowed_cidrs`, `enable_ssh`, `ssh_allowed_cidrs` | Security group rules; effective immediately, even mid-session |
| `backup_retention_days`, `force_destroy_buckets` | S3 lifecycle and bucket settings |
| `route53_ttl` | Terraform sets it on the record; the instance sets the same value at boot |
| `cpu_credits`, `tags` | Instance attributes, updated in place |
| `root_volume_gb` | Volume grows in place; the filesystem follows on the next boot |
| `data_volume_gb` | Volume grows in place; `xfs_growfs` extends the filesystem on the next boot |

### `terraform apply`, then `/stop` and `/start`

The normal path. Everything here is read from SSM on each boot.

Which means none of it reaches a session that is already running. For most
of the list that is merely a delay. For the two cost guards it is a gap worth
naming: turning `shutdown_on_crash` or `max_uptime_hours` on leaves the
current session running under the old value, so restart before you count on
either of them.

`idle_timeout_minutes` · `max_uptime_hours` · `shutdown_on_crash` ·
`uptime_warning_enabled` · `uptime_warning_hours` ·
`discord_notify_player_events` · `discord_webhook_url` · `discord_bot_username` ·
`java_heap_mb` · `minecraft_version` · `fabric_loader_version` ·
`server_jar_url` · `server_mods` · `local_backup_keep` · `addressing_mode` ·
`route53_zone_id` · `route53_record_name` · `manage_server_properties`

With `manage_server_properties = true`, the `server.properties` group in the
next section joins this list too — `server_motd` through `server_port`. The
player lists do not: `server_ops` and `server_whitelist_players` stay with the
in-game commands, which is where they belong.

### First boot only — a live instance needs more

These are read while the server is being created. On an instance that already
exists the Terraform value is ignored, and you change the thing itself instead.

The first two rows are the common ones, and the first has an opt-out:
`manage_server_properties = true` moves that whole group into the normal
apply-and-restart path. The rest genuinely only happen once.

| Setting | Why | What to do instead |
| --- | --- | --- |
| `server_motd`, `server_difficulty`, `server_gamemode`, `server_max_players`, `server_view_distance`, `server_simulation_distance`, `server_online_mode`, `server_whitelist` | Written into `server.properties`, which is only created when absent | Set `manage_server_properties = true` and they apply normally, or edit the file — [below](#serverproperties-settings) |
| `server_ops`, `server_whitelist_players` | Seed `ops.json` / `whitelist.json`, but only while those files are absent | `/op` and `/whitelist` in game — [above](#i-added-someone-to-the-whitelist) |
| `server_port` | The bind port lives in `server.properties`; the firewall rule and the address `/address` reports do follow the variable | `manage_server_properties = true` covers the bind port too, so an apply then does all three. Otherwise apply, then edit the file |
| `java_package` | Packages are installed by `bootstrap.sh`, which cloud-init runs once | Apply, then `sudo mc update && sudo /opt/minecraft/bin/bootstrap.sh` |
| `accept_minecraft_eula` | `eula.txt` is written during the first boot | Edit `/srv/minecraft/server/eula.txt` |
| `restore_from_s3` | Only consulted when there is no world yet | Restore by hand — [operations.md](operations.md#restoring) |
| `stop_after_provisioning` | Only describes what the *first* boot does | Nothing; it has no meaning afterwards |

### Replaces the instance

The world is on its own volume and survives all of these. The **root** volume
does not, so anything installed on the instance by hand is lost.

| Setting | Behaviour |
| --- | --- |
| `instance_type`, same architecture | Updated in place. AWS stops the instance, resizes it and starts it |
| `instance_type`, different architecture | **Replaces the instance.** `t4g` is arm64 and `t3`/`t3a` are x86_64, so crossing between them rebuilds the box. The Elastic IP and the world volume are kept |
| `ssh_key_name` | **Replaces the instance.** EC2 cannot change the key pair on an existing instance, so turning SSH on *with a key* rebuilds it. `enable_ssh` on its own only opens the port |

### Effectively a new deployment

`project_name` · `aws_region` · `vpc_id` · `subnet_id`

These name or place the resources, so changing one builds a second stack rather
than moving the first. Take a backup, `terraform destroy`, then apply with the
new value and `restore_from_s3`.

## The outliers in detail

### `server.properties` settings

By default `bootstrap.sh` writes `server.properties` from the Terraform values
once, on the first boot, and nothing rewrites it afterwards. From that point the
file on the instance is the source of truth, and those Terraform variables
describe how the server *was* created rather than how it is configured now.

That is deliberate — an edit made on the instance is never reverted — but it
does mean `server_motd = "..."` followed by an apply does nothing visible.
There are two ways out.

**Hand the keys to Terraform.** Set:

```hcl
manage_server_properties = true
```

and the managed keys are reconciled into the file on every boot, so those
settings behave like every other setting: change, apply, restart. Nothing else
in the file is touched — a key a mod reads, the world seed, a setting you added
by hand — and the previous version is kept beside it as
`server.properties.bak`.

The keys it owns are exactly the ones this project sets: `server-port`, `motd`,
`difficulty`, `gamemode`, `max-players`, `view-distance`,
`simulation-distance`, `white-list`, `enforce-whitelist` and `online-mode`.

The trade is the one the default exists to protect. With this on, a hand edit to
one of those keys is overwritten at the next restart — and so is an in-game
command that writes back to the file, such as `/difficulty` or
`/whitelist on`. Turn it on if you would rather manage the server from
`terraform.tfvars` than from a shell; leave it off if you tune in place.

**Or edit the file.** [Get to the instance](#getting-to-the-instance), then:

```bash
sudo mc maintenance-stop
sudo nano /srv/minecraft/server/server.properties
sudo mc start
```

Or discard your edits and take the Terraform values again — this works whether
or not `manage_server_properties` is set, because a missing file is always
rewritten from the configuration:

```bash
sudo mc maintenance-stop
sudo rm /srv/minecraft/server/server.properties
sudo mc start
```

### `minecraft_version = "latest"`

`latest` is resolved once, when the jar is first installed, and then held. It
does not follow new Minecraft releases, because that would upgrade a world with
nobody intending it, with no backup taken on purpose and no way back — worlds do
not downgrade.

Pin the version to move deliberately, or force it now:

```bash
sudo mc upgrade --yes
```

The same applies to a jar whose version was never recorded. Both cases are
covered in [upgrading Minecraft](operations.md#upgrading-minecraft).

### Scripts under `server/`

Not a setting, but the same question. `terraform apply` re-zips and uploads
them, and the instance downloads the payload on every boot. To pick them up
without a full stop and start:

```bash
sudo mc update
sudo systemctl restart minecraft
```

## Faster than a stop and a start

The full cycle is the reliable answer, but several things can be applied to a
running instance:

```bash
sudo mc update             # re-download the scripts Terraform uploaded
sudo mc upgrade --yes      # install the configured minecraft_version now
sudo mc console <command>  # anything the server console accepts, live
```

A restart is the one that also re-reads `config.env` from SSM, because
`minecraft.service` pulls in `minecraft-refresh.service`. That makes it the
right answer after a `terraform apply`: the commands above act on the
configuration the instance already has, which is still the previous one.

```bash
sudo systemctl restart minecraft
```

## Checking a change took effect

What the instance currently believes:

```bash
sudo cat /etc/minecraft/config.env
sudo journalctl -u minecraft-refresh | tail
```

`configuration refreshed from /minecraft/config` means the refresh ran. If it
did not, see
[changes to tfvars have no effect](troubleshooting.md#changes-to-tfvars-have-no-effect).

For settings that live in files rather than the environment:

```bash
sudo cat /srv/minecraft/server/server.properties
sudo cat /srv/minecraft/server/whitelist.json
sudo mc mods
sudo mc version
```

---

Related: [making changes by hand](operations.md#making-changes-by-hand) covers
which files on the instance a boot restores and which it leaves alone, and the
[configuration reference](configuration.md) lists every setting with its type
and default.
