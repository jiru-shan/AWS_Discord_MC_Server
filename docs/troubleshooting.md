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

## Every command says "The application did not respond"

Discord shows this whenever nothing answers within three seconds. The commands
appearing in the menu tells you nothing: they are registered with the bot
token, over a completely different path from the one that serves them.

Work out whether the Lambda is being reached at all:

```bash
aws logs tail /aws/lambda/minecraft-discord --since 1h --region <region>
```

**Log lines appear.** The Lambda ran. Read the error there.

**Nothing at all, ever.** Discord is not reaching it. Two causes, and they look
identical from Discord:

1. **The URL is in the wrong field.** It belongs in **General Information ->
   Interactions Endpoint URL**. A Discord application also has an *Event
   Webhooks URL*, and a channel webhook is a third thing entirely -- the one
   you copy *from* for `discord_webhook_url`. In the wrong field it saves
   happily and slash commands still have nowhere to go.

2. **The endpoint is returning 403.** Check it directly:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST \
     -H 'Content-Type: application/json' -d '{"type":1}' \
     "$(terraform -chdir=terraform output -raw discord_interactions_endpoint_url)"
   ```

   `401` is the healthy answer -- the signature check rejecting an unsigned
   request. `403` means AWS refused before your code ran; see below.

## The endpoint URL returns 403 AccessDeniedException

Some AWS accounts will not serve a public Lambda function URL at all. The
symptom is a 403 with `x-amzn-ErrorType: AccessDeniedException`, no invocation
recorded in CloudWatch, and a resource policy that is already correct --
`AuthType: NONE` and a statement allowing `lambda:InvokeFunctionUrl` for
principal `*`. Adding the permission again does not help, because the
permission was never the problem.

To confirm it is the account rather than this deployment, give any throwaway
Lambda a public URL and call it. If that 403s too, nothing here is misconfigured.

The fix is to stop using a function URL:

```hcl
endpoint_type = "api_gateway"
```

`terraform apply` replaces the function URL with an HTTP API in front of the
same Lambda. The handler is unchanged -- API Gateway's 2.0 payload format hands
it the same headers and body a function URL does. It stays inside the free tier
at this volume.

**The URL changes**, so paste the new
`discord_interactions_endpoint_url` output into **Interactions Endpoint URL**
and save again.

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
or a proxy that changes those lines breaks the count, and so does a name the
pattern does not match: usernames are read as at most 16 characters of
`[A-Za-z0-9_]`, which is exactly right for Java Edition and wrong for anything
that prefixes or spaces names, such as a Bedrock bridge.

```bash
sudo mc logs | grep -E 'joined the game|left the game'
sudo mc logs | grep servermanager
```

`[servermanager] no players (...)` lines tell you what it believes. Compare the
two greps: a join line the server logged with no matching
`[servermanager] X joined` means the pattern did not match it, and that player
is invisible to the shutdown decision.

`discord_notify_player_events = true` makes this visible without a shell, since
it posts exactly what the counter saw. Somebody playing with no join posted for
them is the same symptom.

If the count is wrong, raise `idle_timeout_minutes` as a stopgap and check
whether a mod is rewriting join messages.

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

Shutting down after about **thirty minutes with no ready line in the log** is
the startup watchdog rather than the idle timer. The server process was alive
but never finished starting, so no idle countdown was ever armed and nothing
else would have stopped it. The journal says
`Server did not finish starting within 30 minutes`. The usual causes are a mod
hanging during initialisation and a world that will not load; `sudo mc logs`
will be sitting at whatever it got stuck on.

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
internet from the subnet. The guard also covers the steps *before*
`bootstrap.sh` runs — installing `unzip`, downloading the payload from S3 — so a
`dnf` mirror having a bad day or an instance role that has not finished
propagating lands here too. `/var/log/cloud-init-output.log` shows which
command failed, since user-data runs under `set -x`.

To keep a failed first boot up indefinitely instead, set
`shutdown_on_crash = false` and rebuild.

## The instance powered off without the server ever starting

Either the unit failed, or the server process never came up. `on-stop.sh` powers
the instance off in both cases, for the same billing reason as above.

```bash
sudo journalctl -u minecraft --no-pager | tail -40
```

- `Route 53 update failed` or a `die` from `announce-address.sh` — an
  `ExecStartPre` failed, so systemd reports the unit as failed and `on-stop.sh`
  acts on `$SERVICE_RESULT`. See the Route 53 section above.
- `failed to start the server process: spawn ... ENOENT` — the JVM itself could
  not be launched, usually a `java_package` that did not install or a bad
  `JAVA_BIN`. The manager writes the crash sentinel and exits rather than
  waiting on a process that will never run.
- `Server did not finish starting within 30 minutes` — the startup watchdog;
  see the section above.

Set `shutdown_on_crash = false` while debugging so the box stays up between
attempts.

## The instance stays running forever

First, find out. `uptime_warning_enabled = true` posts to Discord once a session
passes `uptime_warning_hours` and again at every multiple of it, which is the
difference between noticing this and noticing it on the bill. A warning saying
**nobody is online** means the idle shutdown itself is not working.

The idle shutdown lives in `servermanager.js`, so it only works while that
process is supervising the server:

```bash
sudo systemctl status minecraft
sudo mc logs | grep servermanager
```

Going through the possibilities:

- **Started by hand.** `java -jar server.jar` in a shell has nothing watching
  it. Stop it and use `sudo mc start`.
- **A player the counter cannot see.** The commonest real cause. The count never
  reaches zero, so the countdown never arms — see
  [the section above](#the-server-shuts-down-while-people-are-playing).
- **Somebody genuinely still connected.** Working as designed: the idle timeout
  deliberately never fires while a player is online, however long they stay.
  An AFK client left overnight bills all night. `max_uptime_hours` is the hard
  cap; the uptime warning is the version that does not disconnect anyone.
- **A maintenance stop.** `journalctl -u minecraft` will say
  `no shutdown sentinel; leaving the instance running for maintenance`. That is
  `mc maintenance-stop` and plain `systemctl stop minecraft` behaving correctly.
- **`idle_timeout_minutes = 0`, or a masked refresh unit.** Zero disables the
  automatic shutdown entirely. `systemctl is-enabled minecraft-refresh` reports
  `masked` if somebody left it that way after a debugging session, in which case
  the instance has stopped picking up configuration from Terraform at all.

```bash
sudo cat /etc/minecraft/config.env | grep -E 'IDLE_TIMEOUT|MAX_UPTIME|SHUTDOWN_ON_CRASH'
systemctl is-enabled minecraft-refresh
```

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

If `journalctl -u minecraft-refresh` shows nothing at all for this boot, check
whether the unit was left masked after a debugging session — masking it is the
documented way to hold a hand-edited `config.env` in place, and an instance left
that way stops tracking Terraform entirely:

```bash
systemctl is-enabled minecraft-refresh     # "masked" is the problem
sudo systemctl unmask minecraft-refresh.service
```

[Making changes by hand](operations.md#making-changes-by-hand) covers which
files are restored on every start and which survive.

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
