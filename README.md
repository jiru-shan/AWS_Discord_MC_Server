# On-demand Minecraft server, started from Discord

A Minecraft server that only exists while people are playing it. Someone types
`/start` in Discord, the server boots and posts its address in the channel; when
the last player leaves it saves, backs up and powers itself off.

You pay for the hours actually played, which for a group that plays a few
evenings a week is roughly the difference between a few dollars a month and
thirty.

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
[eight steps with screenshots](docs/discord-setup.md).

---

## What you need

- An AWS account, and either the AWS CLI configured (`aws configure`) or the
  usual environment variables set.
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer.
- Python 3.9 or newer, for the one-off command registration script. No packages
  to install.
- A Discord server where you can add an application.

No Java, Node or Minecraft anything on your machine: the instance installs its
own.

## Getting it running

**1. Create the Discord application.** Follow
[docs/discord-setup.md](docs/discord-setup.md) up to the point where you have a
**public key**. Stop there and come back; the endpoint URL does not exist yet.

**2. Configure.**

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The two required values are `discord_public_key` and
`accept_minecraft_eula`. Everything else has a working default.

**3. Deploy.**

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

**5. Register the commands.**

```bash
python scripts/register_commands.py --guild <your server ID>
```

**6. Type `/start` in Discord.** The first boot installs Java and downloads the
Minecraft server, so give it about five minutes. Later boots take ninety
seconds.

## The commands

| Command    | What it does                                                       |
| ---------- | ------------------------------------------------------------------ |
| `/start`   | Boots the instance if it is stopped                                 |
| `/stop`    | Saves the world, backs it up and powers the instance off            |
| `/status`  | Reports whether the server is up, and the address if it is          |
| `/address` | Shows the address to connect to                                     |

Restrict them to a role with `discord_allowed_role_ids` if the channel is
public.

## What it costs

For `t4g.medium` in `us-west-2`, the default:

| Item                             | Cost                                      |
| -------------------------------- | ----------------------------------------- |
| EC2 while playing                | about $0.034 per hour                     |
| EBS, 20 GB world + 12 GB root    | about $2.60 a month, always               |
| Elastic IP while stopped         | about $3.60 a month at most (see below)   |
| Lambda, S3, Route 53             | cents                                     |

Roughly **$8-10 a month** for ten hours of play a week. The comparable
always-on instance is about $27.

Two ways to trim it:

- `addressing_mode = "route53"` drops the Elastic IP charge entirely, if you
  already have a domain in Route 53.
- `idle_timeout_minutes` is the main lever. Fifteen minutes is a compromise
  between not shutting down during a bathroom break and not idling for an hour.

## Configuration

Every setting lives in `terraform/terraform.tfvars` and is documented in
`terraform/variables.tf`. The ones people change first:

| Variable                        | Default          | Notes                                                        |
| ------------------------------- | ---------------- | ------------------------------------------------------------ |
| `instance_type`                 | `t4g.medium`     | Architecture and AMI follow automatically                     |
| `minecraft_version`             | `latest`         | Pin it if your mods need a specific version                   |
| `idle_timeout_minutes`          | `15`             | Minutes of nobody online before shutdown                      |
| `addressing_mode`               | `elastic_ip`     | Or `route53` if you have a domain                             |
| `server_whitelist`              | `false`          | Turn on if the port is open to the internet                   |
| `discord_allowed_role_ids`      | `[]`             | Restrict who may start the server                             |
| `restore_from_s3`               | `""`             | Migrate an existing world in on first boot                    |

**Changing settings does not rebuild the instance.** Terraform publishes the
configuration to SSM Parameter Store, and the instance re-reads it on every
boot. Run `terraform apply`, then `/stop` and `/start`, and the change is live.
The same is true of the scripts under `server/`.

## Layout

```
terraform/          Everything in AWS. Start at main.tf.
lambda/             The Discord interactions endpoint.
                    Zero dependencies, including the Ed25519 verifier.
server/bin/         What runs on the instance.
                    servermanager.js holds the idle-shutdown logic.
server/systemd/     The units that run it on every boot.
scripts/            One-off Discord command registration.
tests/              Three suites: python, node and bash. `make test`
docs/               Discord setup, operations, architecture, troubleshooting.
original_code/      The hand-built version this replaces, kept for reference.
```

## Testing

Everything runs locally with no AWS account, no credentials and no packages to
install:

```bash
make test              # all three suites
make test-lambda       # Ed25519 verification + the Discord handler   (python)
make test-session      # the idle-shutdown state machine             (node)
make test-shell        # the on-instance scripts                     (bash)
```

The shell suite runs the real scripts against a stubbed AWS CLI, systemd and
`curl` inside a throwaway filesystem root. It refuses to start if `shutdown`
does not resolve to its stub, so it cannot power off the machine you run it on.

Signature verification is pinned to the RFC 8032 test vectors, so a change to
`ed25519_verify.py` that broke Discord authentication would fail the suite
rather than reach production.

## Operating it

Open a root shell without SSH keys or an open port:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo mc status
```

`mc` is a small admin CLI on the instance: `mc status`, `mc logs -f`,
`mc console <command>`, `mc backup`, `mc stop`, `mc update`.

See [docs/operations.md](docs/operations.md) for backups, restores, mods and
version upgrades, and [docs/troubleshooting.md](docs/troubleshooting.md) when
something is wrong.

## Notes on the original

`original_code/` is the working hand-built version this project generalises.
Two things in it need action, since they are committed to git history:

- **The Discord webhook URL in `servermanager.js` is live.** Anyone with the
  repository can post to that channel. Delete the webhook in Discord channel
  settings and create a new one; put the new URL in `terraform.tfvars`, which
  is gitignored.
- The Discord application public key and AWS account ID are also in there.
  Neither is secret, but they identify your deployment.

Rotating the webhook removes the only real exposure. Removing them from history
as well needs a rewrite (`git filter-repo`) and a force push.
