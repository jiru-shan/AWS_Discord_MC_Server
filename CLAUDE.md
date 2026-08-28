# Notes for working on this repository

Guidance for anyone — or any assistant — changing this project. The README is
the user-facing documentation; this is the part that is easy to get wrong.

An on-demand Minecraft server: a Discord slash command reaches a Lambda, the
Lambda starts an EC2 instance, the instance publishes its address, runs a
Fabric server, and powers itself off once nobody has played for a while. The
whole cost model rests on that last step working.

## Layout

| Directory         | What it holds                                                    |
| ----------------- | ---------------------------------------------------------------- |
| `terraform/`      | All AWS resources. `terraform apply` provisions the whole stack.  |
| `lambda/`         | Discord interactions endpoint. Zero dependencies, including a pure-Python Ed25519 verifier (PyNaCl needs a compiled wheel). |
| `server/bin/`     | Runs on the instance. `servermanager.js` holds the idle-shutdown logic; `update-server-jar.sh`, `install-mods.js` and `seed-players.sh` reconcile the box against config on every boot. |
| `server/systemd/` | Units that run the server on every boot.                          |
| `scripts/`        | Discord slash-command registration; the config-docs generator.    |
| `tests/`          | Four suites: python, two node, bash. `make test` — no dependencies, no AWS. |
| `docs/`           | Setup guides, operations, troubleshooting. `configuration.md` is generated -- edit `variables.tf`, run `make docs`; a test fails if it drifts. |

### Things worth knowing before changing it

- **Configuration is not baked into the instance.** Terraform publishes it to
  one SSM parameter; `minecraft-refresh.service` re-reads it, and re-downloads
  `server/` from S3, on every boot before the server starts. So `terraform
  apply` plus a stop/start applies changes with no instance replacement. Do not
  move settings into user-data, which cloud-init runs only once.

- **Both addressing modes are supported** (`addressing_mode`): a static Elastic
  IP, or the original Route 53 dynamic-DNS approach. The instance publishes
  whichever applies at boot.

- **Code lives on the root volume (`/opt/minecraft`), the world on a separate
  EBS volume (`/srv/minecraft`).** They must not overlap: mounting the data
  volume over the payload directory would hide the scripts that mounted it.

- **`/run/minecraft/idle-shutdown` decides whether the instance powers off.**
  `on-stop.sh` runs on every service stop and only shuts down when that sentinel
  is present, so maintenance (`systemctl stop minecraft`) never powers the box
  off unexpectedly.

- **Mods are reconciled, not installed once.** `install-mods.js` runs as an
  `ExecStartPre` on every boot and makes `mods/` match `server_mods`. Two rules
  are load-bearing: a jar with no build for the running Minecraft version is
  *deleted*, because Fabric refuses to boot with a mismatched mod and a crash
  loop is worse than a slow server; and only jars recorded in
  `mods/.managed.json` are ever touched, so hand-placed jars survive. Nothing
  in it may fail the boot.

- **`minecraft_version` is reconciled at boot, and `latest` deliberately does
  not follow.** `update-server-jar.sh` compares the configured version against
  `$SERVER_DIR/.minecraft-version` and, on a change, backs up and reinstalls --
  before `install-mods.js`, so mods resolve against the version about to run.
  `latest` resolves once and then holds: auto-following it would upgrade a
  world with no intended backup, and worlds do not downgrade. A failed upgrade
  keeps the old jar and starts on it.

- **Idle detection parses the server log through `readline`, not raw chunks.**
  The original tested `data.includes(...)` on stdout chunks, which silently
  drops an event whenever a chunk boundary lands mid-line.

- **`/stop` never calls `ec2:StopInstances`.** It runs `request-stop.sh` on the
  instance via SSM so the world is saved and backed up first. The Lambda has no
  stop permission on purpose.
