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
| `server/bin/`     | Runs on the instance. `servermanager.js` holds the idle-shutdown logic; `update-server-jar.sh`, `install-mods.js`, `seed-players.sh` and `apply-properties.sh` reconcile the box against config on every boot. |
| `server/systemd/` | Units that run the server on every boot.                          |
| `scripts/`        | Discord slash-command registration; the config-docs generator.    |
| `tests/`          | Four suites: python, two node, bash. `make test` — no dependencies, no AWS. Must pass on Linux, macOS and Git Bash; see below. |
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

- **`server.properties` is seeded, not owned -- unless asked.** `bootstrap.sh`
  writes it once and nothing rewrites it, so hand edits and in-game commands
  survive. `apply-properties.sh` reverses that for the keys Terraform sets, and
  only when `manage_server_properties` is true. It reconciles the managed subset
  in place rather than regenerating the file: comments, blank lines, the world
  seed and any key a mod reads are copied through untouched, and the previous
  file is kept as `.bak`. Adding a key to the managed list there means adding it
  to the list `bootstrap.sh` writes too, or the two drift.

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

- **Three things stop the instance, and all of them have to keep working.**
  The idle countdown is only the first. The second is the startup watchdog in
  `createSession`: the ready line is the *only* thing that arms the idle timer,
  so a server that never prints it -- a mod hanging in init, a world that will
  not load -- has no countdown at all, and the watchdog is what catches it. The
  third is `servermanager.js` exiting: a JVM that cannot be spawned emits
  `error` and `close` but never `exit`, so the teardown is reachable from both
  or the process sits holding the console FIFO open, the unit stays `active`,
  and `ExecStopPost` never runs. Anything added to this file that can hang or
  exit early belongs behind one of the three.

- **The first boot has no backstop, so user-data guards itself.** Until
  `bootstrap.sh` has installed `minecraft.service` there is no `ExecStopPost`
  to power the box off, and cloud-init never retries. The `EXIT` trap in
  `user_data.sh.tftpl` therefore covers the whole script, not just the
  bootstrap call: a `dnf` mirror hiccup or an instance role that has not
  finished propagating fails *above* it, and those are the likelier failures.

- **`on-stop.sh` bounds its backup.** systemd kills the whole stop sequence at
  `TimeoutStopSec`, and tar + gzip + an S3 upload of a world that grows every
  session has no natural ceiling. If the backup overruns, the SIGKILL lands
  before `shutdown -h now` and the instance is left up with nothing running on
  it. Losing one backup is recoverable; missing the power-off is billed hourly.

- **`notify()` is synchronous, and player events must never use it.** It shells
  out to curl through `execFileSync`, which is fine for the handful of lifecycle
  messages and wrong for one per join: while it runs, nothing is reading the
  server's stdout, and a stdout pipe that fills blocks the JVM itself. Joins and
  leaves go through `createEventQueue` instead -- one request in flight,
  everything that arrives meanwhile coalesced into the next, bounded so an
  unreachable webhook cannot grow it. Anything else that fires during play
  belongs there too.

- **The suite runs on Linux, macOS and Git Bash, and that constrains what the
  scripts may use.** macOS still ships bash 3.2 and no `timeout(1)`; Debian and
  Ubuntu ship no `python` (only `python3`); Windows ships no `python3` and puts
  non-functional shims for both names on PATH. So: no bash 4 builtins
  (`mapfile`, `declare -A`) anywhere the tests reach, no GNU-only tool without a
  fallback, and resolve the interpreter by *running* each candidate rather than
  locating it. `run.sh` does that once and exports `$PY`; `jq` and `unzip` are
  stubbed in Python so the promise of "nothing to install" is real. Checking a
  change on one platform is not checking it.

- **Idle detection parses the server log through `readline`, not raw chunks.**
  The original tested `data.includes(...)` on stdout chunks, which silently
  drops an event whenever a chunk boundary lands mid-line.

- **`/stop` never calls `ec2:StopInstances`.** It runs `request-stop.sh` on the
  instance via SSM so the world is saved and backed up first. The Lambda has no
  stop permission on purpose.
