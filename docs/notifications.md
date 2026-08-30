# Discord notifications

By default the server starts and stops in silence. The slash commands reply to
whoever ran them, but nothing announces that the server came up, and nothing
says it has gone away again — so the first anyone knows about the shutdown is
finding they cannot connect.

A channel webhook fixes that. It takes about a minute to set up and is the
single highest-value optional thing in this project.

```
Server is up. Connect at `184.33.68.111`
Server stopped due to inactivity.
```

---

## Why a webhook and not the bot

The bot answers *interactions* — someone types `/start`, Discord calls the
Lambda, the Lambda replies to that one request. That is a conversation, and it
is over in three seconds.

The messages here are different: they are sent by the **instance**, minutes or
hours later, with nobody having asked for anything. For the bot to post them it
would need a gateway connection or a stored bot token on the instance, which
means a credential on a machine exposed to the internet, and permissions to
post as the application. A channel webhook is a single URL that can post to one
channel and do nothing else — much less to lose.

That is why the token from [step 4 of the Discord setup](discord-setup.md#4-create-the-bot-and-copy-its-token)
is never given to AWS, and this is a separate thing.

## What gets sent

Everything the instance can tell you, in the order you would normally meet it:

| Message | When |
| --- | --- |
| ``Server is up. Connect at `address` `` | the server finished loading and is accepting connections |
| `Server stopped due to inactivity.` | nobody online for `idle_timeout_minutes`; world saved and backed up |
| `Server stopped.` | a stop that was asked for — `/stop`, or the `max_uptime_hours` cap |
| `Minecraft server exited unexpectedly (code N).` | a crash, with the last 15 log lines in a code block |
| `Minecraft server failed to start: …` | the JVM could not be launched at all |
| `Minecraft server failed to start (result). Shutting the instance down.` | the unit failed before the server ran — for example the address could not be published |
| `Minecraft updated from X to Y.` | a `minecraft_version` change was applied on boot |
| `Minecraft update to Y failed; still running X.` | the upgrade could not be completed; the old version is still serving |
| `Minecraft upgrade to Y was skipped: the pre-upgrade backup failed.` | refused to upgrade because there would have been no way back |
| `Setup finished. The server is installed and the instance is off` | first boot with `stop_after_provisioning = true` |
| `` `Alice` joined (2 online) ``, `` `Alice` left (1 online) `` | a player joined or left, with `discord_notify_player_events = true` |
| `The server has been up for N hours and … still online …` | `uptime_warning_enabled = true`, every `uptime_warning_hours` |
| `The server has been up for N hours with nobody online.` | the same warning on an empty server, which means the idle shutdown did not run |

The crash and failure messages are the ones that earn their keep. Without them
a server that dies at 2am looks identical to a server that idled out normally,
and you find out days later.

### Join and leave messages

Off by default, because it is the only notification that fires *during* play
rather than around it:

```hcl
discord_notify_player_events = true
```

Each join and leave posts one line — `` `Alice` joined (2 online) `` — with the
count after the change. Names are wrapped in backticks so an underscore in a
username is not read as Discord italics.

A busy evening is a lot of messages, and a server people drift in and out of
produces more than most channels want mixed in with conversation. If you turn
it on, point `discord_webhook_url` at a channel of its own.

Two properties worth knowing:

- **Messages can arrive batched.** Posts go out one request at a time, and
  anything that happens while a request is in flight is folded into the next
  message. Four people joining at once may arrive as one four-line post. This
  is deliberate: the notifier must never block the process that supervises the
  server, and it keeps a reconnect storm inside Discord's rate limit.
- **These are the same events the shutdown decision runs on.** So the channel
  doubles as a window onto the idle timer. If somebody is playing and no join
  was ever posted for them, the server does not know they are there — and will
  idle out from under them at the timeout. A join with no matching leave means
  the opposite: the count is stuck above zero and the server will not idle out
  at all.

### Long-session warnings

Off by default. Turn them on when you want to hear about a session that is
still running hours later:

```hcl
uptime_warning_enabled = true
uptime_warning_hours   = 6      # first warning at 6h, then 12h, 18h, ...
```

The idle countdown only ever fires on an *empty* server, so a session with one
person still connected — or one AFK client nobody closed — has nothing bounding
it except `max_uptime_hours`, which is off by default and, when on, ends the
session outright while people may still be playing. These warnings are the
in-between: they cost nothing, interrupt nobody, and put the running total
where somebody will see it.

The two wordings mean quite different things:

- **with players online** — working as designed. Somebody is connected, so the
  idle timer has correctly not fired. The message is a reminder, not a fault.
- **with nobody online** — something is wrong. An empty server should have shut
  itself down after `idle_timeout_minutes`. Read `journalctl -u minecraft` on
  the instance; the usual cause is a join or leave line the log watcher never
  saw, which leaves the player count stuck above zero.

They stop when the server stops, and they need `discord_webhook_url` — without
a webhook there is nowhere to post, and the warning is written only to the
journal.

## Setting it up

### 1. Create the webhook in Discord

This is in **channel** settings, not the developer portal:

**Right-click the channel** you want the messages in → **Edit Channel** →
**Integrations** → **Webhooks** → **New Webhook** → **Copy Webhook URL**.

You are copying a URL Discord generates. There is nothing to paste in.

Pick the channel deliberately. These messages are useful but frequent enough to
be noise in a busy channel — a `#minecraft` or `#server-status` channel is
better than `#general`.

### 2. Put it in `terraform.tfvars`

```hcl
discord_webhook_url  = "https://discord.com/api/webhooks/123456789/aBcDeF..."
discord_bot_username = "Minecraft Server"
```

`discord_bot_username` is the display name on the messages. It does not have to
match the bot; it is just a label on the webhook post.

**This URL is a credential.** Anyone holding it can post to that channel as
your webhook, forever, with no further authentication. `terraform.tfvars` is
gitignored — keep it that way, and do not paste the URL into an issue or a
chat.

### 3. Apply

```bash
terraform apply
```

Terraform writes it to SSM Parameter Store as a `SecureString`, so it is
encrypted at rest and never appears in the instance's configuration file or in
Terraform's output. The instance reads it at boot and caches it in `/run`,
which is tmpfs and therefore gone on every power-off.

Then `/stop` and `/start` in Discord — or wait for the next session — so the
instance picks it up.

### 4. Check it

The next time the server comes up you should see the "Server is up" message.
To test without waiting, from a shell on the instance:

```bash
sudo /opt/minecraft/bin/notify.sh "test message"
```

## Turning it off

```hcl
discord_webhook_url = ""
```

Notifications are skipped entirely and nothing else changes. The settings that
depend on a webhook stop mattering rather than needing to be turned off too:
`discord_notify_player_events` is forced off by Terraform, and a long-session
warning is written to the journal instead of a channel.

## Rotating it

If the URL has been shared or committed anywhere:

1. Channel → **Edit Channel** → **Integrations** → **Webhooks**
2. **Delete** the old webhook — this invalidates the URL immediately
3. Create a new one and copy the URL
4. Update `discord_webhook_url`, `terraform apply`
5. `/stop` then `/start`, so the instance drops its cached copy

## If no messages arrive

**Nothing at all, and the server is definitely running.** Check what the
instance thinks it has:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo grep DISCORD_WEBHOOK_SSM_PARAM /etc/minecraft/config.env
```

An empty value means `discord_webhook_url` is unset, or was set but the
instance has not rebooted since the apply.

**Configured, still silent.** The notification path deliberately never fails
the server, so problems are logged rather than raised:

```bash
sudo journalctl -u minecraft | grep -i notify
```

- `notify (no webhook configured)` — the parameter is empty or reads as `None`
- `notify failed (webhook rejected or unreachable)` — the URL is wrong, or the
  webhook was deleted in Discord

**Messages arrive but ping everyone.** They should not: every post sets
`allowed_mentions: {parse: []}`, so a server name containing `@everyone` is
inert. If you are seeing pings, something else is posting them.

**A crash message with no log block.** The server died before producing any
output — usually a JVM that will not start at all. `sudo mc logs` has the rest.

---

Related: [configuration reference](configuration.md#discord) for the exact
variables, [Discord setup](discord-setup.md) for the bot itself,
[operations](operations.md) for what to do once something has gone wrong.
