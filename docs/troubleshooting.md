# Troubleshooting

Roughly in the order things go wrong.

## Discord will not accept the interactions endpoint URL

Discord sends two requests when you save: a correctly signed PING, and a
deliberately corrupted one. It accepts the endpoint only if the first returns
`200 {"type": 1}` and the second returns `401`.

Read the Lambda logs while you click Save:

```bash
aws logs tail /aws/lambda/minecraft-discord --follow
```

| What you see                                    | Cause                                                       |
| ----------------------------------------------- | ----------------------------------------------------------- |
| Nothing at all                                   | Wrong URL. Re-copy `discord_interactions_endpoint_url`, including the trailing slash. |
| `KeyError: 'DISCORD_PUBLIC_KEY'`                 | Apply did not finish. Re-run `terraform apply`.               |
| 401 on every request                             | Wrong public key — see below.                                 |
| `Runtime.ImportModuleError`                      | `ed25519_verify.py` missing from the zip. Re-run `terraform apply`; check `lambda/` has both `.py` files. |

The most common cause is pasting the wrong value into `discord_public_key`. It
is the **Public Key** from General Information — not the Application ID, not the
client secret, not the bot token. Sixty-four hex characters.

Verify what is actually deployed:

```bash
aws lambda get-function-configuration --function-name minecraft-discord \
  --query 'Environment.Variables.DISCORD_PUBLIC_KEY'
```

## The slash commands do not appear in Discord

- **Registered globally?** Global commands take up to an hour. Re-run with
  `--guild <server ID>` for instant registration.
- **Bot invited with `applications.commands`?** The `bot` scope alone is not
  enough. Regenerate the OAuth2 URL with both scopes and re-add the bot.
- **Right server?** `python scripts/register_commands.py --list --guild <id>`
  shows what Discord actually has.
- Fully quit and reopen the Discord client. It caches the command list
  aggressively.

## `/start` says "Could not find the server instance"

The Lambda has an instance ID that no longer exists — usually after a
`terraform destroy` and re-apply where the Lambda was not updated. Run
`terraform apply` again.

## `/start` works but nobody can connect

Check where it got to:

```bash
aws ssm start-session --target <instance-id>
sudo mc status
sudo mc logs -f
```

**First boot takes about five minutes.** It installs Java, downloads the Fabric
launcher, and the launcher then downloads the Minecraft server and its
libraries. Watch it:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

Then, in order:

1. **Is the server actually up?** `sudo mc logs | grep Done` — you want
   `Done (21.5s)! For help, type "help"`.
2. **Right address?** `sudo mc address`. In `route53` mode also check the record
   resolves: `dig +short mc.example.com`. If it still returns `192.0.2.1`, the
   boot script did not update it — see below.
3. **Security group open?** `allowed_cidrs` defaults to `0.0.0.0/0`. If you
   narrowed it, confirm your players are inside it.
4. **Right port?** Non-default `server_port` must be typed by players as
   `address:port`.

## The DNS record is still 192.0.2.1

`192.0.2.1` is the placeholder Terraform creates. That it survived means
`announce-address.sh` failed.

```bash
sudo journalctl -u minecraft.service | grep -i route53
```

- `AccessDenied` — the instance policy scopes `route53:ChangeResourceRecordSets`
  to one record name in one zone. Confirm `route53_record_name` in your tfvars
  exactly matches the record, and re-apply.
- `NoSuchHostedZone` — wrong `route53_zone_id`. It is the zone ID (`Z...`), not
  the domain name.

[route53-setup.md](route53-setup.md#troubleshooting) covers the rest, including
the case where the name does not resolve anywhere because the domain is still
delegated to another registrar.

## The server shuts down while people are playing

Player counting reads `joined the game` and `left the game` from the log. A mod
or a proxy that changes those lines breaks the count.

```bash
sudo mc logs | grep -E 'joined the game|left the game'
sudo mc logs | grep servermanager
```

`[servermanager] no players (...)` lines tell you what it believes. If the count
is wrong, raise `idle_timeout_minutes` as a stopgap and check whether a mod is
rewriting join messages.

## The server shuts down immediately after starting

Normal if nobody joins: the idle timer starts as soon as the server is ready.
With the default it powers off fifteen minutes after `/start` if the channel
goes quiet.

Shutting down in *seconds* means it crashed — `shutdown_on_crash` is true by
default so a crash loop cannot run up a bill. The Discord notification includes
the last log lines. To keep the box up while you investigate:

```hcl
shutdown_on_crash = false
```

Apply, then `/start`, then `sudo mc logs`.

## The first boot failed and the instance is stopping in 30 minutes

Deliberate. A first-boot failure happens before `minecraft.service` exists, so
the shutdown path that normally powers the instance off never runs -- and a
broken instance would otherwise bill indefinitely without anyone noticing. The
Discord notification says what happened and user-data schedules `shutdown -h
+30`, leaving half an hour to look.

```bash
aws ssm start-session --target <instance-id>
sudo tail -100 /var/log/cloud-init-output.log
sudo shutdown -c            # cancel the pending shutdown while you work
```

Common causes, in order: `accept_minecraft_eula` not set to true; a
`minecraft_version` Fabric does not publish a loader for; no route to the
internet from the subnet.

To keep a failed first boot up indefinitely instead, set
`shutdown_on_crash = false` and rebuild.

## The instance powered off without the server ever starting

The unit failed rather than the server exiting. `on-stop.sh` powers the instance
off when systemd reports the unit as failed, for the same billing reason as
above -- most often because `announce-address.sh` could not publish the address.

```bash
sudo journalctl -u minecraft --no-pager | tail -40
```

See the Route 53 section above. Set `shutdown_on_crash = false` while debugging
so the box stays up between attempts.

## The instance stays running forever

The idle shutdown lives in `servermanager.js`, so it only works while that
process is supervising the server.

```bash
sudo systemctl status minecraft
sudo mc logs | grep servermanager
```

If you started the server by hand (`java -jar server.jar`) instead of through
the service, nothing is watching it. Stop it and use `sudo mc start`.

Check the sentinel logic too: a stop that leaves the instance up is
`maintenance-stop` behaviour, and `journalctl -u minecraft` will say
`no shutdown sentinel; leaving the instance running for maintenance`.

## `terraform apply` fails

**`no-public-subnet-found--set-subnet_id-explicitly`** — the account has no
default VPC, or none of its subnets auto-assign public IPs. Set `vpc_id` and
`subnet_id` to a public subnet explicitly.

**`InvalidParameterCombination: ... does not support ...`** — the instance type
does not exist in that region, or is not burstable while `cpu_credits` is set.
Try another type or region.

**`BucketAlreadyExists`** — the bucket is named
`<project_name>-<account>-<region>`, so this means another stack in the same
account and region uses that `project_name`. Change it.

**`EntityAlreadyExists` on an IAM role** — leftovers from a previous stack with
the same `project_name`. Either import them or pick a new name.

## Changes to tfvars have no effect

Expected: the instance reads its configuration at boot.

```bash
terraform -chdir=terraform apply   # publish
# then /stop and /start in Discord
```

To confirm what the instance is running with:

```bash
sudo cat /etc/minecraft/config.env
sudo journalctl -u minecraft-refresh
```

`configuration refreshed from /minecraft/config` means it worked.

Settings already written into `server.properties` are the exception: that file
is only generated when absent, so hand edits are never clobbered. Edit it
directly, or delete it and restart.

## Terrible performance

- `cpu_credits = "standard"` (the default) throttles a burstable instance to its
  baseline once credits run out — very noticeable during world generation.
  `"unlimited"` costs a few cents an hour more and removes the cliff.
- Lower `server_view_distance` to 8 or 6. It is the cheapest win available.
- Check the optimisation mods are actually installed: `sudo mc mods` should
  list Lithium, FerriteCore and Krypton. If they are missing,
  `sudo journalctl -u minecraft | grep '\[mods\]'` says why — usually no build
  yet for the Minecraft version you are on. See
  [operations.md](operations.md#mods), which also lists what else is worth
  adding.
- Move up an instance size. The default `t4g.small` is 2 GB, which is a
  couple of players on a vanilla world; `t4g.medium` is 4 GB and `t4g.large`
  is 8 GB for a modpack. Both leave the free tier.

## Reading the logs

```bash
# On the instance
sudo mc logs -f                                # server + servermanager
sudo journalctl -u minecraft-refresh           # boot-time config refresh
sudo tail -f /var/log/cloud-init-output.log    # first boot only

# From your machine
aws logs tail /aws/lambda/minecraft-discord --follow
```
