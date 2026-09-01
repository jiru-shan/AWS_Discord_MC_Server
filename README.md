# On-demand Minecraft server, started from Discord

[![tests](https://github.com/jiru-shan/AWS_Discord_MC_Server/actions/workflows/test.yml/badge.svg)](https://github.com/jiru-shan/AWS_Discord_MC_Server/actions/workflows/test.yml)

A Minecraft server that only exists while people are playing it. Someone types
`/start` in Discord and the server boots; when the last player leaves it saves,
backs up and powers itself off.

Point a [channel webhook](docs/notifications.md) at it and it announces itself
too — "Server is up. Connect at ..." on the way in, "Server stopped due to
inactivity." on the way out.

You pay for the hours actually played, which for a group that plays a few
evenings a week is roughly the difference between a few dollars a month and
thirty.

The defaults are sized to stay inside the AWS Free Tier: a `t4g.small`
instance and 28 GB of disk, which on an eligible account is free outright.
[What it costs](#what-it-costs) has the allowances, and the one line to change
if you would rather have a bigger server than a free one.

```
Discord  ──/start──▶  Lambda  ──StartInstances──▶  EC2 instance
                        ▲                              │
                        │                       boots, publishes its
                     verifies the                address, runs Fabric
                     Ed25519 signature                  │
                                                 no players for 15 min
                                                        │
   "Server stopped due to inactivity."  ◀── webhook ── saves, backs up
                                                       to S3, shuts down
```

Everything is provisioned by Terraform. The only manual work is on the Discord
side, which has no API for creating an application; that part is
[ten steps, about ten minutes](docs/discord-setup.md).

---

## What you need

- Linux, macOS or Windows. Everything here works on all three; on Windows, run
  the shell commands from Git Bash rather than PowerShell.
- An AWS account, and either the AWS CLI configured (`aws configure`) or the
  usual environment variables set. **Include a default region.** Without one
  every `aws` command fails against a malformed endpoint that names everything
  except the problem -- `sts..amazonaws.com` when the region is simply unset,
  or `sts.None.amazonaws.com` when something has written the literal string
  `None` into `~/.aws/config`. `aws configure` asks for a region, and an
  environment-variable setup needs `AWS_DEFAULT_REGION` alongside the key pair.
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer.
- Python 3.9 or newer, for the one-off command registration script. No packages
  to install. It is `python3` on Linux and macOS, usually `python` on Windows.
- A Discord server where you can add an application.
- Optional, and only for opening a shell on the instance: the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
  It installs separately from the AWS CLI, and `aws ssm start-session` fails
  without it. Nothing in the deployment needs it.

No Java, Node or Minecraft anything on your machine to deploy it: the instance
installs its own.

### Windows notes

Everything here works from Git Bash, with three quirks worth knowing before
they bite. None of them affect the deployment -- they are all about reading
things back afterwards.

**Arguments that start with a slash get rewritten.** Git Bash turns a
leading-slash argument into a Windows path, so a CloudWatch log group name
arrives at the CLI as `C:/Program Files/Git/aws/lambda/...` and the call fails
validation. Prefix the command:

```bash
MSYS_NO_PATHCONV=1 aws logs tail /aws/lambda/minecraft-discord --follow
```

This applies to any `aws` argument beginning with `/` -- log group names above
all. Paths *inside* the instance are typed in a shell on the instance, so they
are unaffected.

**Instance logs need a UTF-8 console.** systemd writes arrow characters, and
the AWS CLI on a `cp1252` console dies on them with `'charmap' codec can't
encode character '\u2192'` rather than printing the log:

```bash
export PYTHONUTF8=1        # once per shell, before reading instance logs
```

**`make` is usually absent, and `python3` often is too.** Every `make` target
is a one-line command you can run directly -- see [Testing](#testing) for the
test suites, and the `Makefile` itself for the rest. The interpreter is
normally `python` rather than `python3`.

## Getting it running

**1. Create the Discord application.** Follow
[docs/discord-setup.md](docs/discord-setup.md) as far as **step 6**, which
leaves you with a **public key** and, if you want notifications, a **webhook
URL**. Both go in `terraform.tfvars` in the next step, so collecting them
together saves applying twice. Stop before step 7 and come back; the endpoint
URL does not exist yet.

**2. Configure.**

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The two required values are `discord_public_key` and
`accept_minecraft_eula`. Everything else has a working default.

> [!IMPORTANT]
> **Most settings stay Terraform's. A few are handed over on the first boot.**
> `server_mods`, `minecraft_version`, the idle timeout and every notification
> setting are re-read on every boot, so change those whenever. The ones below
> are different: Terraform writes them once and then the instance owns the
> file, which is what stops an in-game `/op`, `/whitelist add` or `/difficulty`
> being silently reverted on the next restart. The price is that editing them
> in `terraform.tfvars` afterwards does nothing. Set them now — and if you are
> already past that, the last column is the way back.

| Set before the first apply | Why | If you are already past it |
| --- | --- | --- |
| `server_motd`, `server_difficulty`, `server_gamemode`, `server_max_players`, `server_view_distance`, `server_simulation_distance`, `server_online_mode`, `server_whitelist` | Written into `server.properties` on the first boot and never rewritten | Turn on `manage_server_properties`, or edit the file on the instance |
| `server_port` | Written into `server.properties` the same way, and it also moves the firewall rule and the address `/address` reports | The apply moves the firewall on its own; the port inside the file needs `manage_server_properties` or an edit |
| `java_package`, `restore_from_s3` | Used once, while the instance is being built | Nothing re-applies these to an instance that exists |
| `server_ops`, `server_whitelist_players` | Seed `ops.json` and `whitelist.json`, and only while those files do not exist. Once they do, the in-game `/op` and `/whitelist` own them. Use real Minecraft account names — a name Mojang does not know is skipped, with a line in the journal and no operator | `/op` and `/whitelist add` in game. The seeding is retried on every boot, so it still applies if the file is missing |

`manage_server_properties = true` takes the first two rows back into Terraform's
hands: those keys are reconciled on every boot like anything else. The price is
the one the default is avoiding — hand edits and in-game `/difficulty` are
overwritten at the next restart. It is off by default because that is the
worse surprise of the two.

[Applying changes](docs/applying-changes.md) lists what every setting needs,
and how to change a first-boot one after the fact.

**3. Deploy.**

> [!WARNING]
> This creates the server, and its first boot is what writes `server.properties`
> and installs Java. Go back and set the table above now if you have not —
> afterwards each of those settings needs its own route, listed in the last
> column and in full under
> [a different route](docs/applying-changes.md#first-boot-only--a-live-instance-needs-more).

```bash
terraform init
terraform apply
```

About two minutes. The output ends with the interactions endpoint URL and a
short list of what to do next.

**4. Finish the Discord setup.** Paste the `discord_interactions_endpoint_url`
output into **Interactions Endpoint URL** on the application page and save.
Discord immediately sends a signed test request; if the page saves without
complaint, the endpoint is verified.

**5. Register the commands.** Discord will not show a slash command until it
has been registered against the application. This is one HTTP call that
Terraform cannot make for you: it needs the **bot token**, which is a
credential Discord never hands to AWS.

```bash
python3 scripts/register_commands.py --guild <your server ID>
```

It needs three values, which are easy to mix up:

| Value              | Identifies                             | Where to get it                                                                                                | Secret  |
| ------------------ | -------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------- |
| **Application ID** | your application, in the API path      | Developer portal → **General Information** → **Application ID** → **Copy**. The OAuth2 page calls the same number **Client ID**. | No      |
| **Bot token**      | you, to Discord — it authorises the call | Developer portal → **Bot** → **Reset Token**. Displayed once.                                                    | **Yes** |
| **Server ID**      | which server to register the commands in | Discord app → **Settings** → **Advanced** → **Developer Mode** on, then right-click your server icon → **Copy Server ID**. | No      |

The first two come from the developer portal, the third from the Discord client
itself. The script prompts for the application ID and bot token, or reads
`DISCORD_APPLICATION_ID` and `DISCORD_BOT_TOKEN` from the environment; the
server ID is what you pass to `--guild`.

All three are long strings of digits and hex, and the same two pages also hold
a **public key** (step 1, for Terraform) and a **client secret** (unused here).
Picking the wrong one is the usual cause of a 401 — the script says so when it
happens.

`--guild` registers to that one server and the commands appear the moment the
script finishes. Leaving it off registers globally, which covers every server
the bot is in but takes up to an hour to show up — use `--guild` while setting
up. Re-run it whenever you change the command list; it sends the whole set at
once, so removals take effect too.

```bash
python3 scripts/register_commands.py --list --guild <your server ID>
```

shows what is currently registered. If it fails, or the commands do not appear,
[docs/discord-setup.md](docs/discord-setup.md#9-register-the-slash-commands)
covers this step in full, including what each of the two credentials is for.

**6. Type `/start` in Discord.**

Note that `terraform apply` has already booted the instance once — an EC2
instance cannot be created stopped — and that boot installs Java, formats the
world volume and fetches Fabric. So the server is most likely up already, and
`/start` will tell you so. If nobody joins it shuts itself down after
`idle_timeout_minutes`, and every later `/start` takes about ninety seconds.

If you would rather `terraform apply` left nothing running, set
`stop_after_provisioning = true`: the instance still boots once to install
everything, then powers off without starting the server.

## Worth adding next

Three optional settings that change the experience more than anything else in
the reference. All three are re-read on every boot, so they can go in at any
point — apply, then `/stop` and `/start`.

### Announcements in Discord

```hcl
discord_webhook_url = "https://discord.com/api/webhooks/..."
```

Without it the server starts and stops in silence, so the first anyone knows
about a shutdown is finding they cannot connect. With it you get
``Server is up. Connect at `1.2.3.4` `` on the way in,
`Server stopped due to inactivity.` on the way out, and a crash report with the
last log lines when something dies at 2am. It is a channel webhook rather than
the bot, so no credential goes near the instance. One minute to set up:
**[Notifications](docs/notifications.md)**.

### A domain instead of four numbers

```hcl
addressing_mode     = "route53"
route53_zone_id     = "Z0000000000000000000"
route53_record_name = "mc.example.com"
```

Players type `mc.example.com` and never learn the IP. It also drops the Elastic
IP charge, which is the first thing on the bill once the twelve-month free tier
ends — so on an older account this is cheaper as well as nicer. Needs a domain
already served by Route 53: **[Route 53 setup](docs/route53-setup.md)**.

### Performance mods

```hcl
server_mods = ["lithium", "ferrite-core", "krypton"]   # the default
```

On by default, and the reason a 2 GB `t4g.small` is worth running at all.
Players install nothing. The list is reconciled against `mods/` on every boot,
and anything a mod needs to load is fetched with it, so adding one is a line
here and a restart. More below in [Mods](#mods), in full in
**[docs/mods.md](docs/mods.md)**.

## The commands

| Command    | What it does                                                       |
| ---------- | ------------------------------------------------------------------ |
| `/start`   | Boots the instance if it is stopped                                 |
| `/stop`    | Saves the world, backs it up and powers the instance off            |
| `/status`  | Reports whether the server is up, and the address if it is          |
| `/address` | Shows the address to connect to                                     |

Restrict them to a role with `discord_allowed_role_ids` if the channel is
public.

### Who can stop the server

`/stop` ends the session for everyone who is playing, which on a shared server
is worth putting behind something. Two settings, and they can be combined:

```hcl
allow_stop_command    = false          # nobody stops it by hand; it idles out
discord_stop_role_ids = ["1234567890"] # or: only this role may stop it
```

With `allow_stop_command = false` the command stays registered and replies to
whoever ran it — privately — saying it is disabled and how long the server
waits when empty. It does not disappear from the menu, which is better than
leaving people to wonder whether they typed it wrong.

This is enforced twice. The Lambda refuses the command, and Terraform also
withholds the `ssm:SendCommand` permission that carries it out, so a deployment
where nobody may end a session cannot have one ended by a bug in the handler
either.

You can still stop it as an operator, from a shell on the instance:

```bash
sudo mc stop
```

## What it costs

The defaults are `t4g.small` in `us-west-2` with 28 GB of EBS, picked so that
everything the stack uses falls inside a free-tier allowance:

| Item                        | Free allowance                                        | What the defaults use                      | Rate after that     |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------ | ------------------- |
| EC2 `t4g.small`             | 750 hours a month, any account, through 31 Dec 2026    | the hours actually played                  | $0.0168 an hour     |
| EBS gp3                     | 30 GB                                                  | 28 GB: 8 GB root + 20 GB world             | $0.08 per GB-month  |
| Public IPv4 (the Elastic IP)| 750 hours a month, first 12 months                     | about 730, since the address is held while the instance is stopped | $0.005 an hour, about $3.60 a month |
| S3 backups                  | 5 GB                                                   | one world archive per backup, expiring after 30 days | $0.023 per GB-month |
| Lambda, SSM, CloudWatch     | far more than this uses                                | a handful of requests a day                | cents               |

So on a free-tier account and at the defaults, **a server for a few friends is
free**, and the first thing to actually bill you is the Elastic IP once the
twelve months are up.

### Free tier eligibility

Which instance types count as free depends on when the AWS account was opened:

- **Opened on or after 15 July 2025.** The account is on the Free Plan, and the
  eligible types are `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`,
  `c7i-flex.large` and `m7i-flex.large`. The plan refuses to launch anything
  else, which is the error you get if you set `instance_type` to something
  larger.
- **Opened before that.** The twelve-month free tier covers `t2.micro` and
  `t3.micro`, and the separate T4g free trial covers 750 hours a month of
  `t4g.small` for every account, new or old, until 31 December 2026.

`t4g.small` is the default because it is the only type that is free on either
kind of account *and* large enough to run a Minecraft server. The micro types
are free too, but they have 1 GB of memory, and the JVM plus a world will not
fit in it. The heap is sized from instance memory automatically, so
`t4g.small` runs with 1 GB of heap and 1 GB left for the OS.

Without the free tier, the same defaults come to about **$6.50 a month** for
ten hours of play a week -- $0.67 of EC2, $2.24 of disk and $3.60 of Elastic
IP. The comparable always-on instance is about $16.

Three levers:

- **Room for more players.** `instance_type = "t4g.medium"` doubles memory to
  4 GB for about $0.034 an hour, and leaves the free tier. Do that if 5
  players on one world is not enough.
- **[`addressing_mode = "route53"`](docs/route53-setup.md)** drops the Elastic
  IP charge entirely, and gives players `mc.example.com` instead of four
  numbers. Needs a domain served by Route 53.
- **`idle_timeout_minutes`** is the main lever on EC2 hours. Fifteen minutes is
  a compromise between not shutting down during a bathroom break and not idling
  for an hour.

### What keeps it from running up a bill

The instance stops itself, and every way that could fail is closed separately —
a crash, a JVM that will not launch, a server that never finishes starting, a
first boot that dies before the shutdown path exists. [Architecture](docs/architecture.md#nothing-is-left-billing-after-a-failure)
walks through each one.

The case none of that covers is a session with somebody genuinely still
connected: the idle timeout deliberately never fires while a player is online,
so an AFK client left overnight bills all night. Two settings address it, and
they are different tools:

```hcl
uptime_warning_enabled = true    # the default; says so in Discord, ends nothing
max_uptime_hours       = 12      # not the default; disconnects whoever is playing
```

The warning is on by default because it is safe to leave on: it ends nothing and
interrupts nobody. It also tells you when the idle shutdown has broken, since a
warning saying nobody is online means exactly that. `max_uptime_hours` is the
one you opt into.


## Configuration

Every setting lives in `terraform/terraform.tfvars`. **[The configuration
reference](docs/configuration.md) documents every one of them** — type, default,
and the accepted values where a setting only takes a few. It is generated from
`terraform/variables.tf`, and a test fails the build if it drifts, so it always
describes what the code actually accepts.

The ones people change first:

| Variable                        | Default          | Notes                                                        |
| ------------------------------- | ---------------- | ------------------------------------------------------------ |
| `instance_type`                 | `t4g.small`      | Free-tier eligible. Architecture and AMI follow automatically  |
| `minecraft_version`             | `latest`         | Pin it to upgrade deliberately — [how](#upgrading-minecraft)   |
| `idle_timeout_minutes`          | `15`             | Minutes of nobody online before shutdown                      |
| `stop_after_provisioning`       | `false`          | `true` means `terraform apply` leaves nothing running          |
| `addressing_mode`               | `elastic_ip`     | Or `route53` if you have a domain — [setup](docs/route53-setup.md) |
| `server_mods`                   | 3 optimisation mods | Fabric mods, reconciled on every boot — [guide](docs/mods.md) |
| `discord_webhook_url`           | `""`             | Post up/down messages to a channel — [setup](docs/notifications.md) |
| `uptime_warning_enabled`        | `true`           | Warns in Discord when a session has run for hours. Ends nothing — [why](#what-it-costs) |
| `server_whitelist`              | `true` recommended | The port is open to the internet — [why](docs/operations.md#whitelisting-and-moderation) |
| `server_ops`                    | `[]`             | Operators; they moderate in-game, so config only seeds the first |
| `endpoint_type`                 | `function_url`   | Switch to `api_gateway` if the endpoint returns 403 — [why](docs/troubleshooting.md#the-endpoint-url-returns-403-accessdeniedexception) |
| `allow_stop_command`            | `true`           | `false` leaves idle shutdown as the only way off — [below](#who-can-stop-the-server) |
| `discord_stop_role_ids`         | `[]`             | Restrict `/stop` to admins, leaving the rest open              |
| `discord_allowed_role_ids`      | `[]`             | Restrict who may use the commands at all                      |
| `restore_from_s3`               | `""`             | Migrate an existing world in on first boot                    |

**Changing settings does not rebuild the instance.** Terraform publishes the
configuration to SSM Parameter Store, and the instance re-reads it on every
boot. Run `terraform apply`, then `/stop` and `/start`, and the change is live.
The same is true of the scripts under `server/`.

Not every setting works that way. **[Applying changes](docs/applying-changes.md)
lists what each one needs** — the settings that apply without a restart, the
ones that only count on the first boot, and the two that rebuild the instance.

### Getting the configuration reference

[docs/configuration.md](docs/configuration.md) is checked in, so reading it on
GitHub or in your editor needs nothing at all. Regenerate it after editing
`terraform/variables.tf`:

```bash
make docs                                # or, without make:
python3 scripts/generate_config_docs.py
```

No packages, no AWS credentials, no Terraform — it parses `variables.tf` and
writes the file.

```bash
python3 scripts/generate_config_docs.py --check   # exit 1 if it is out of date
```

`make check` runs that, and `make test` makes the same assertion from
`tests/test_config_docs.py`. So a variable whose description, default or
validation changed without the reference being regenerated fails the build.
That is the whole point of generating it: the reference cannot quietly describe
a version of the settings that no longer exists.

Adding a variable therefore documents itself — write the `description`, the
`type`, the `default` and any `validation` block in `variables.tf`, run `make
docs`, and the new entry appears with its accepted values extracted from the
validation.

## Mods

The server runs Fabric, so `server_mods` is a list Terraform publishes and the
instance reconciles against `mods/` on every boot — added entries are
downloaded, removed entries deleted, and a Minecraft version change re-resolves
all of them.

```hcl
server_mods = ["lithium", "ferrite-core", "krypton"]   # the default
```

Those three are the reason a 2 GB `t4g.small` is worth running. They are
server-side only: nothing is required of players' clients, and no Fabric API
is needed.

| Mod            | What it does                                                                      |
| -------------- | --------------------------------------------------------------------------------- |
| `lithium`      | Rewrites the hot paths of the game tick. The largest single win, and changes no behaviour. |
| `ferrite-core` | Cuts heap use sharply — on a 1 GB heap this is the difference between headroom and GC pauses. |
| `krypton`      | Lighter networking, felt most when several players load chunks at once.            |

Entries are Modrinth project slugs, a slug pinned to one build
(`lithium@0.15.0`), or an `https://` URL ending in `.jar` for anything not on
Modrinth. Jars you copy into `mods/` by hand are never touched, so that path
stays open for private or client-side mods.

A mod with no build for the running Minecraft version is skipped and its old
jar removed, because Fabric refuses to start rather than run a mismatched mod.
Losing an optimisation is recoverable; a crash loop on a box with no open port
is much less so. Failures are logged and never block the server from starting.

On the instance, `sudo mc mods` lists what is installed and which entries are
managed, and `sudo systemctl restart minecraft` applies a changed list without
waiting for a boot.

**[docs/mods.md](docs/mods.md)** is the full guide: which mods are worth
adding, what players need installed on their end, editing mod and server
configuration, tuning for more players, and upgrading Minecraft without
breaking your mods.

## Upgrading Minecraft

Set the version and apply. There is no manual step on the instance:

```hcl
# terraform/terraform.tfvars
minecraft_version = "1.21.4"
```

```bash
terraform apply
```

Then `/stop` and `/start` in Discord. On that boot the instance notices the
installed version no longer matches the configured one and, in this order:

1. **Backs the world up** to the data volume and to S3.
2. Downloads the Fabric launcher for the new version.
3. **Re-resolves every mod** against it, so nothing is left behind built for
   the old version.

`sudo mc version` shows where you actually are:

```
installed:  1.21.3
configured: 1.21.4
```

**`latest` does not auto-upgrade, on purpose.** It is resolved once, when the
jar is first installed, and then stays put. Following it automatically would
upgrade your world the first time Mojang shipped a release — with no backup
anyone intended, no check that your mods have builds for it, and no way back.
Pin a version when you want to move; `sudo mc upgrade --yes` moves a `latest`
server on demand.

**Worlds do not downgrade.** Once a world has been opened by a newer Minecraft
the older one cannot open it again, so the pre-upgrade backup is the only route
back. That is why the upgrade refuses to proceed at all if the backup fails.

Nothing here can leave you without a server. If the download fails, or Fabric
has no build for that version, the old jar stays in place, the server starts on
the version it was already running, and it says so in the journal and in
Discord. A failed upgrade costs you a version, not an evening.

The one thing that genuinely breaks is **mods**: a mod with no build for the
new version is dropped, and named in the log. See
[docs/mods.md](docs/mods.md#upgrading-minecraft-with-mods-installed).

## Layout

```
terraform/          Everything in AWS. Start at main.tf.
lambda/             The Discord interactions endpoint.
                    Zero dependencies, including the Ed25519 verifier.
server/bin/         What runs on the instance. servermanager.js holds the
                    idle-shutdown logic; install-mods.js, update-server-jar.sh,
                    seed-players.sh and apply-properties.sh reconcile the box
                    against the configuration on every boot.
server/systemd/     The units that run it on every boot.
scripts/            One-off Discord command registration.
tests/              Four suites: python, two node, bash. `make test`
docs/               Setup guides, the configuration reference, operations.
                    configuration.md is generated -- `make docs`.
```

## Testing

Everything runs locally with no AWS account, no credentials and no packages to
install:

```bash
make test              # every suite
make test-lambda       # Ed25519 verification + the Discord handler   (python)
make test-session      # the idle-shutdown state machine             (node)
make test-mods         # the Fabric mod installer                    (node)
make test-shell        # the on-instance scripts                     (bash)
make docs              # regenerate docs/configuration.md
```

Without `make` -- which Windows generally does not have -- each target is a
single command. Use `python` in place of `python3` where that is the name you
have:

```bash
python3 -m unittest discover -s tests    # test-lambda
node --test tests/test_session.js        # test-session
node --test tests/test_mods.js           # test-mods
bash tests/shell/run.sh                  # test-shell
python3 scripts/generate_config_docs.py  # docs
```

The shell suite runs the real scripts against a stubbed AWS CLI, systemd and
`curl` inside a throwaway filesystem root. It refuses to start if `shutdown`
does not resolve to its stub, so it cannot power off the machine you run it on.

The suites need `bash`, Python 3.9+ and Node 20+ and nothing else: `jq` and
`unzip` are stubbed in Python, and the `timeout` macOS does not ship is
substituted, so there is nothing to install on any of the three platforms.

Signature verification is pinned to the RFC 8032 test vectors, so a change to
`ed25519_verify.py` that broke Discord authentication would fail the suite
rather than reach production.

## Operating it

Open a root shell without SSH keys or an open port:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo mc status
```

This one command needs the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
which installs separately from the AWS CLI; without it `start-session` fails
before it reaches AWS. The instance must also be running, so `/start` first.
`terraform -chdir=terraform output -raw shell_command` prints the same command
with the region already filled in.

`mc` is a small admin CLI on the instance: `mc status`, `mc logs -f`,
`mc console <command>`, `mc backup`, `mc mods`, `mc version`, `mc upgrade`,
`mc stop`, `mc update`.

## Documentation

| | |
| --- | --- |
| [Discord setup](docs/discord-setup.md) | The manual half: creating the application, the bot, the webhook, and registering the commands. Ten steps. |
| [Configuration reference](docs/configuration.md) | Every setting, with type, default and accepted values. Generated from `variables.tf`. |
| [Route 53 setup](docs/route53-setup.md) | Running on `mc.example.com` instead of an IP: hosted zones, delegation, TTLs, costs. |
| [Notifications](docs/notifications.md) | Getting "Server is up", crashes, joins and leaves, and long-session warnings posted to a channel. Optional, one minute to set up. |
| [Mods](docs/mods.md) | Adding mods, what players need, mod and server configuration, tuning for more players. |
| [Applying changes](docs/applying-changes.md) | What each setting needs before it takes effect: the usual apply-and-restart, and the settings that do not work that way. |
| [Operations](docs/operations.md) | Day to day: shells, backups, restores, applying changes, editing things by hand, Minecraft upgrades, watching costs. |
| [Architecture](docs/architecture.md) | How the pieces fit and why they are arranged this way. |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-first, from "Discord will not accept the endpoint" to "the instance stays running forever". |

## Licence

Apache 2.0. See [LICENSE](LICENSE).

Minecraft is a trademark of Mojang Studios; this project is not affiliated with
Mojang or Microsoft. Running a server requires accepting the
[Minecraft EULA](https://aka.ms/MinecraftEULA), which is what
`accept_minecraft_eula` does.
