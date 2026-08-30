# Mods and server configuration

The server runs [Fabric](https://fabricmc.net/), so mods are jars in
`/srv/minecraft/server/mods`. This project manages that directory from
Terraform rather than leaving it to you.

Two separate things are covered here, because in practice you change them
together: **which mods are installed**, and **how the server and those mods are
configured**.

- [How the mod sync works](#how-the-mod-sync-works)
- [Adding a mod](#adding-a-mod)
- [Which mods are worth it](#which-mods-are-worth-it)
- [Client-side mods, and what players need](#client-side-mods-and-what-players-need)
- [Configuring a mod](#configuring-a-mod)
- [Server settings](#server-settings)
- [Tuning for more players](#tuning-for-more-players)
- [Upgrading Minecraft with mods installed](#upgrading-minecraft-with-mods-installed)
- [When something breaks](#when-something-breaks)

---

## How the mod sync works

`server_mods` is a list in `terraform/terraform.tfvars`. Terraform publishes it
to SSM; `install-mods.js` runs on the instance as an `ExecStartPre` of
`minecraft.service` and makes the directory match the list — **every boot**, not
just the first.

```
terraform apply  ──▶  SSM parameter  ──▶  install-mods.js  ──▶  mods/
                                          (before the JVM starts)
```

Each boot it resolves every entry against the running Minecraft version,
downloads what is missing, deletes what you removed, and leaves everything else
alone. Three rules make it safe to run unattended:

**A jar with no build for the running version is deleted.** Fabric does not
degrade with a mismatched mod, it refuses to start. Since the only way into a
broken instance is SSM, and the instance powers itself off, a crash loop is far
worse than a missing optimisation. So when the game version moves and a mod has
not caught up, its jar goes.

**A transient failure keeps what is working.** If Modrinth is unreachable but
the Minecraft version has not changed, the jars already installed are correct,
and they stay. Only a version change forces the delete above.

**Jars you install by hand are never touched.** The sync only removes files
recorded in `mods/.managed.json`. Anything else in the directory is yours.

Nothing here can stop the server starting: failures are logged under `[mods]`
and the unit invokes the script with a `-` prefix.

## Adding a mod

Find the mod on [Modrinth](https://modrinth.com/mods?g=categories:fabric) and
take the **slug** — the last segment of its URL:

```
https://modrinth.com/mod/ferrite-core
                          ^^^^^^^^^^^^
```

Add it to the list and apply:

```hcl
server_mods = ["lithium", "ferrite-core", "krypton", "alternate-current"]
```

```bash
terraform apply
```

Then `/stop` and `/start` in Discord. Or, without waiting for a boot:

```bash
aws ssm start-session --target $(terraform -chdir=terraform output -raw instance_id)
sudo mc mods sync              # re-resolve, download, prune
sudo systemctl restart minecraft
sudo mc mods                   # what is installed now
sudo mc logs -f                # watch it come up
```

Fabric reads `mods/` once, at launch, so a sync always needs a restart.

### The three entry formats

| Entry | Resolves to |
| --- | --- |
| `lithium` | the newest release build of that Modrinth project for the running Minecraft version |
| `lithium@0.15.0` | that exact Modrinth version, by `version_number` or version ID |
| `https://example.com/thing.jar` | a direct download |

Modrinth downloads are verified against the SHA-1 the API publishes. A direct
URL has nothing to verify against, so use Modrinth wherever the mod is on it.
`http://` URLs are refused outright — these jars execute inside the server
process, and over plaintext the jar you get is whoever is on the path's choice.

Pinning with `@` is worth doing when a mod update has broken you before, or
when you want a reproducible deployment. The cost is that a Minecraft upgrade
will then fail to resolve that pin and drop the mod, which is loud but sudden.

### Removing a mod

Delete it from the list, apply, restart. Its jar is deleted; a mod's config file
in `config/` is left behind, which is what you want if you are only testing.

## Which mods are worth it

Everything in this table is **server-side**: players join with a stock
Minecraft client and install nothing. None of them need the Fabric API.

| Mod | What it buys | Notes |
| --- | --- | --- |
| `lithium` | The general tick optimiser — mob AI, block ticks, pathfinding, chunk saving. The largest single win available. | **Default.** Behaviour-preserving by design; it does not change game logic. |
| `ferrite-core` | Large reduction in heap use. | **Default.** The one that matters most at 1 GB of heap: less heap used is less time in garbage collection. |
| `krypton` | Networking stack optimisations. | **Default.** Felt with several players loading chunks at once. |
| `alternate-current` | A redstone implementation that is dramatically cheaper than vanilla's. | Worth adding the moment anyone builds a farm or a clock. |
| `servercore` | Dynamic view distance and other server-side tuning that backs off under load. | Trades render distance for TPS automatically, which is the right trade on a small instance. |
| `c2me-fabric` | Parallel chunk generation and I/O. The fix for lag while exploring new terrain. | Trades **memory** for threads. Add it on `t4g.medium` and up; on the 2 GB default it can cost more than it gives. |
| `spark` | A profiler. `/spark tps` and `/spark profiler` say what is actually slow. | Not an optimisation — a way to stop guessing. Worth having installed before you need it. |
| `chunky` | Pre-generates terrain with `/chunky start`, so exploring is not also generating. | Run it once over the area you play in, then remove it from the list. |

A note on where the wins come from: `lithium` and `ferrite-core` help every
session. `alternate-current`, `c2me-fabric` and `chunky` each fix one specific
kind of lag, and are only worth their memory if you have that kind. Install
`spark` and look before adding the others.

### Finding others

Modrinth's [Fabric performance
category](https://modrinth.com/mods?g=categories:fabric&g=categories:optimization)
is the place to browse. Check two things on any candidate:

- **Environments** — "Server" must be supported. A client-only mod in a server
  `mods/` directory is at best inert.
- **Versions** — it must list the Minecraft version you run. If it does not,
  adding it does nothing except log a warning; the sync skips it.

## Client-side mods, and what players need

A mod is *server-side* if the server can run it while clients are unmodified.
Everything above is. Two other cases exist:

**Mods requiring a matching client install.** Anything that adds blocks, items,
dimensions or recipes. Every player needs the same mod and the same Fabric
loader, and connecting without it fails at handshake with a version-mismatch
screen. This project has no mechanism for distributing those — you send people
the jars, or point them at a launcher profile.

**Mods some players want and the server does not care about.** Sodium, Iris,
Xaero's minimap. These go on the player's machine and never touch
`server_mods`. If a player asks whether they may use one, the answer is
generally yes and the server does not need to know.

If you do go down the modpack route, `instance_type = "t4g.medium"` or
`"t4g.large"` first — a modpack on 1 GB of heap will not start.

## Configuring a mod

Fabric mods read config files from `/srv/minecraft/server/config/`, created by
the mod on its first run. They live on the data volume, so they survive
instance replacement, and the sync never touches them.

```bash
sudo mc maintenance-stop                        # stop the server, keep the box up
sudo ls /srv/minecraft/server/config
sudo nano /srv/minecraft/server/config/lithium.properties
sudo chown minecraft:minecraft /srv/minecraft/server/config/lithium.properties
sudo mc start
```

Use `mc maintenance-stop`, not `systemctl stop`, if you want the instance to
stay up while you edit — though both are safe. The instance only powers off
when `/run/minecraft/idle-shutdown` is present, which a maintenance stop does
not create.

Most of the defaults are fine. `lithium` in particular exposes per-optimisation
toggles that exist for debugging a suspected incompatibility, not for tuning.

### Mods installed by hand

The escape hatch for private builds or anything with no public URL:

```bash
sudo mc maintenance-stop
sudo curl -L -o /srv/minecraft/server/mods/private.jar '<url>'
sudo chown minecraft:minecraft /srv/minecraft/server/mods/private.jar
sudo mc start && sudo mc logs -f
```

`sudo mc mods` lists these as `manual` rather than `managed`. They are never
removed by a sync — including when the Minecraft version changes, so these are
yours to keep current. [Making changes by hand](operations.md#making-changes-by-hand)
covers the same distinction for the rest of the instance: what a boot restores
from Terraform, and what it leaves alone.

## Server settings

`server.properties` is generated from Terraform variables on the **first** boot
only, and never rewritten after that. This is so hand edits on the instance
survive, but it does mean changing one of these variables later has no effect
on an existing server.

Set `manage_server_properties = true` to reverse that: the keys below are then
reconciled on every boot, so changing one is an apply and a restart like any
other setting — at the cost of the hand edits this default protects. See
[applying changes](applying-changes.md#serverproperties-settings).

| Variable | Property |
| --- | --- |
| `server_motd` | `motd` |
| `server_difficulty` | `difficulty` |
| `server_gamemode` | `gamemode` |
| `server_max_players` | `max-players` |
| `server_view_distance` | `view-distance` |
| `server_simulation_distance` | `simulation-distance` |
| `server_online_mode` | `online-mode` |
| `server_whitelist` | `white-list`, `enforce-whitelist` |
| `server_port` | `server-port` |

Full types, defaults and accepted values are in the [configuration
reference](configuration.md#minecraft).

**To change one on a running server**, edit the file directly:

```bash
sudo mc maintenance-stop
sudo nano /srv/minecraft/server/server.properties
sudo mc start
```

**Or regenerate it** from the current Terraform values — this discards every
hand edit in that file, and nothing else:

```bash
terraform apply                                       # publish the new values
sudo mc maintenance-stop
sudo rm /srv/minecraft/server/server.properties
sudo /opt/minecraft/bin/bootstrap.sh                  # rewrites it, safe to re-run
sudo mc start
```

`ops.json` and `whitelist.json` work the same way: `server_ops` and
`server_whitelist_players` seed them on a fresh install, and after that the
in-game `/op` and `/whitelist` commands own them.

Two settings are deliberately fixed and not exposed:

- `spawn-protection=0` — a single-group server does not want a protected spawn.
- `pause-when-empty-seconds=0` — the idle shutdown in `servermanager.js` needs
  the server responsive so it can save and stop cleanly. Letting Minecraft
  pause itself would fight it.

## Tuning for more players

On the default `t4g.small` (2 GB, 1 GB heap) with the three default mods, a
vanilla world comfortably holds 4–6 players. The ceiling is memory, and you
meet it as garbage-collection stutter rather than as a crash.

In the order worth trying:

**1. Lower the distances.** The cheapest win by a distance, and the one players
notice least:

```hcl
server_view_distance       = 8   # from 10; chunks sent to each client
server_simulation_distance = 6   # from 10; how far entities and redstone tick
```

Simulation distance is the one that costs CPU. View distance costs memory and
bandwidth. Dropping simulation to 6 and leaving view at 10 keeps the world
looking the same while ticking much less of it.

**2. Add `alternate-current` and `servercore`.** Both server-side, both free of
client requirements.

**3. Profile before guessing.** Add `spark`, then in-game:

```
/spark tps          # is it actually below 20?
/spark profiler     # what is eating the tick
```

**4. Pre-generate with `chunky`.** If the lag is specifically when someone
explores, the cost is chunk generation, and generating it in advance while
nobody is playing moves it off the critical path.

**5. Then buy memory.** `instance_type = "t4g.medium"` doubles it to 4 GB for
about $0.034/hour and leaves the free tier — see [what it
costs](../README.md#what-it-costs). The heap follows instance memory
automatically unless you set `java_heap_mb`.

## Upgrading Minecraft with mods installed

Mods are the reason to be careful about `minecraft_version`. The default,
`latest`, follows Fabric's newest stable release — and in the weeks after a
Minecraft release, mods have not caught up.

The safe pattern is to pin, and move deliberately:

```hcl
minecraft_version = "1.21.4"
```

1. **Check your mods first.** The Versions tab on each Modrinth page. Anything
   without a build for the new version will be dropped — see below.
2. **Change `minecraft_version` and `terraform apply`.**
3. **`/stop` and `/start`.**

That is the whole upgrade. On the next boot the instance notices the installed
version no longer matches the configured one, backs the world up, installs the
new Fabric launcher, and *then* re-resolves the mods — in that order, so every
mod is resolved against the version actually about to run.

`minecraft_version = "latest"` deliberately does **not** auto-upgrade; it is
resolved once and then holds. `sudo mc upgrade --yes` moves such a server on
demand.

**Mods are the thing that breaks.** A mod with no build for the new version is
skipped and its old jar deleted, because Fabric refuses to start with a
mismatched mod. You get a working server with fewer optimisations, and a
warning naming each mod that was dropped:

```bash
sudo journalctl -u minecraft | grep '\[mods\]'
```

Re-run that a week later; mods catch up, and the next boot picks them up with
no action from you. If a mod matters more than the version does, pin
`minecraft_version` back to one it supports — but only before the world has
been opened on the newer version.

**Worlds do not downgrade.** Once a world has been opened on a newer Minecraft,
going back means restoring the backup from step 2. See
[operations.md](operations.md#restoring).

## When something breaks

The installer logs every decision it makes:

```bash
sudo journalctl -u minecraft | grep '\[mods\]'
```

**A mod is not installed and `mc mods` does not list it.** Almost always no
build for your Minecraft version. The log line says so. Either wait, pin
`minecraft_version` to one the mod supports, or drop the mod.

**The server will not start after a mod change.** Read the Fabric error at the
top of `sudo mc logs`; it names the mod and what it wanted. Then:

```bash
sudo mc maintenance-stop
sudo mv /srv/minecraft/server/mods/<offender>.jar /tmp/
sudo mc start
```

and remove that entry from `server_mods` so the next sync does not put it back.

**Two mods conflict.** Fabric names both in the crash. There is no general fix;
remove one. The default three have no known conflicts with each other or with
anything in the table above.

**A mod needs the Fabric API.** Some do — add `fabric-api` to `server_mods`.
None of the mods recommended here require it.

**Everything is installed and it is still slow.** That is a sizing problem, not
a mod problem. Go back to [tuning for more
players](#tuning-for-more-players), and use `spark` rather than guessing.

---

Related: [configuration reference](configuration.md) for every setting,
[operations.md](operations.md) for backups and upgrades,
[troubleshooting.md](troubleshooting.md) when the server itself is unhappy.
