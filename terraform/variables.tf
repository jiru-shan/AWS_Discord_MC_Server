# --------------------------------------------------------------------------
# Naming and placement
# --------------------------------------------------------------------------

variable "project_name" {
  description = "Prefix for every resource name. Use a different value to run more than one server in an account."
  type        = string
  default     = "minecraft"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must be lowercase letters, digits and hyphens, 2-31 characters."
  }
}

variable "aws_region" {
  description = "Region to deploy into. Pick one close to your players; it is the single biggest lever on latency."
  type        = string
  default     = "us-west-2"
}

variable "vpc_id" {
  description = "VPC to launch into. Leave empty to use the default VPC for the account."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet to launch into. Leave empty to pick the first default subnet in the VPC. Must be a public subnet."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------
# Compute
# --------------------------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    EC2 instance type. Graviton (t4g) is roughly 20% cheaper than the x86
    equivalent and runs Fabric fine; the architecture and AMI are selected
    automatically from whatever you put here.

    The default is free-tier eligible: t4g.small is covered by the T4g free
    trial (750 hours a month, every account, through 31 December 2026) and is
    also on the free-tier list for accounts opened on or after 15 July 2025.
    It is the smallest type that runs a Minecraft server at all -- the micro
    types in the free tier have 1 GB of memory, which the JVM cannot work in.

    Rough guide: t4g.small (2 GB) for 2-3 players on a light world,
    t4g.medium (4 GB) for up to about 8, t4g.large (8 GB) for a modpack.
    Anything above t4g.small is billed at the normal on-demand rate.

    Changing size within a family is applied in place: AWS stops the instance,
    resizes it and starts it again. Changing architecture (t4g -> t3) replaces
    the instance instead, which Terraform plans on its own -- the replacement
    picks up the AMI for the new architecture, so no -replace flag is needed.
    The world is on its own volume either way; only the root volume is lost.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "root_volume_gb" {
  description = <<-EOT
    Root volume size. Holds the OS and the scripts only; the world lives on the
    data volume. Amazon Linux, Java and Node come to about 4 GB.

    The default plus data_volume_gb is 28 GB, which fits the 30 GB of EBS the
    free tier covers. Raising either past that budget starts a monthly charge.
  EOT
  type        = number
  default     = 8
}

variable "data_volume_gb" {
  description = <<-EOT
    Persistent volume for the world, backups and mods. Survives instance
    replacement. Counts against the same 30 GB free-tier EBS budget as
    root_volume_gb.

    Growing this is applied in place, and the filesystem is grown to match on
    the next boot -- so raise it, apply, then /stop and /start. It can only be
    grown: EBS will not shrink a volume, and neither will XFS.
  EOT
  type        = number
  default     = 20
}

variable "server_mods" {
  description = <<-EOT
    Fabric mods to install, reconciled against the mods directory on every
    boot: entries added here are downloaded, entries removed are deleted, and a
    Minecraft version change re-resolves all of them.

    Each entry is a Modrinth project slug, a slug pinned to one build
    (`lithium@0.15.0`), or an https URL ending in .jar for anything not on
    Modrinth. Jars copied into the directory by hand are never touched.

    The default three are server-side only, need no Fabric API and require
    nothing of players' clients. They are what makes the free-tier t4g.small
    hold more than a couple of people:

      lithium      rewrites the hot paths of the game tick. The single
                   biggest win, and behaviour-preserving.
      ferrite-core cuts heap use substantially, which on a 2 GB instance is
                   the difference between headroom and garbage-collection
                   pauses.
      krypton      lighter networking, mostly felt with several players
                   loading chunks at once.

    A mod with no build for the running Minecraft version is skipped, and its
    jar removed if one was installed for an older version -- Fabric refuses to
    start rather than run a mismatched mod. Set this to [] to run vanilla.

    Requirements are handled for you. After each jar is downloaded its
    fabric.mod.json is read, and anything the installed set does not already
    provide is fetched too -- adding "spark" pulls in Fabric API, and the
    journal says which mod asked for it. Modrinth's own dependency list is
    consulted first and is not trusted alone: spark declares nothing there and
    still refuses to load without Fabric API, so the jar is the source of truth.

    A requirement nothing known can supply is named in the journal rather than
    installed on a guess.
  EOT
  type        = list(string)
  default     = ["lithium", "ferrite-core", "krypton"]

  validation {
    condition = alltrue([
      for mod in var.server_mods :
      can(regex("^https://[^ ]+[.]jar$", mod)) || can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}(@[^@ ]+)?$", mod))
    ])
    error_message = "Each server_mods entry must be a Modrinth slug, slug@version, or an https:// URL ending in .jar."
  }
}

variable "java_heap_mb" {
  description = "Java heap size in MB. 0 sizes it from the memory of the instance, leaving 1 GB for the OS."
  type        = number
  default     = 0
}

variable "java_package" {
  description = <<-EOT
    JDK package to install.

    Minecraft raises its Java requirement periodically and Fabric fails hard on
    a JVM that is too old: the server exits at once with
    UnsupportedClassVersionError rather than starting degraded. The default
    tracks the newest Corretto LTS in Amazon Linux 2023, which runs every older
    Minecraft too -- the JVM is backward compatible, so there is no reason to
    pin this lower than the newest release you might install.

    Class file versions, if you have to read one of those errors: 61 is Java
    17, 65 is Java 21, 69 is Java 25.

    Unlike almost everything else here, changing this does not take effect on
    the next boot: packages are installed by bootstrap.sh, which cloud-init
    runs once. On a live instance, apply and then re-run it by hand --
    `sudo mc update && sudo /opt/minecraft/bin/bootstrap.sh` -- or replace the
    instance. The world is on its own volume and survives either.
  EOT
  type        = string
  default     = "java-25-amazon-corretto-headless"
}

# --------------------------------------------------------------------------
# Addressing
# --------------------------------------------------------------------------

variable "addressing_mode" {
  description = <<-EOT
    How players reach the server, given the public IP changes on every boot.

      elastic_ip - attach a static IP. No domain needed. Costs about $3.60 a
                   month for the hours the instance is stopped; free while it
                   is running.
      route53    - the boot script repoints an A record at the new IP. Needs a
                   hosted zone you control. No idle charge.
      none       - players read the raw IP from /status each session.
  EOT
  type        = string
  default     = "elastic_ip"

  validation {
    condition     = contains(["elastic_ip", "route53", "none"], var.addressing_mode)
    error_message = "addressing_mode must be one of: elastic_ip, route53, none."
  }
}

variable "route53_zone_id" {
  description = "Hosted zone ID. Required when addressing_mode is route53."
  type        = string
  default     = ""
}

variable "route53_record_name" {
  description = "Fully qualified name for the A record, for example mc.example.com. Required when addressing_mode is route53."
  type        = string
  default     = ""

  # The instance's IAM policy pins this exact name through
  # route53:ChangeResourceRecordSetsNormalizedRecordNames, which AWS matches
  # against the name lowercased, stripped of its trailing dot, and with every
  # character outside a-z 0-9 - _ . replaced by a 	hree-digit octal escape.
  # lower(trimsuffix(...)) in main.tf covers the first two; it cannot produce
  # the third. A name needing an escape -- a wildcard, an internationalised
  # domain -- would therefore build a policy that never matches, and every boot
  # would fail with an AccessDenied that names nothing useful.
  #
  # A single label is refused for a different reason: Terraform would read it
  # as relative to the zone, while announce-address.sh sends it to the API
  # verbatim, where it is absolute. The two would disagree about which record
  # they mean.
  validation {
    condition = var.route53_record_name == "" || can(regex(
      "^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?([.][A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?)+[.]?$",
      var.route53_record_name
    ))
    error_message = "route53_record_name must be a fully qualified name built from letters, digits, hyphens, underscores and dots, for example mc.example.com. Wildcards and internationalised domains cannot be expressed in the instance's IAM policy and would fail every boot with AccessDenied."
  }
}

variable "route53_ttl" {
  description = "TTL for the A record. Keep it short so a restart propagates quickly."
  type        = number
  default     = 30
}

variable "server_port" {
  description = <<-EOT
    Port the server listens on.

    Changing this after the first boot needs one manual step. The security
    group and the address the bot reports both follow immediately, but the port
    the server actually binds lives in server.properties, which is written once
    and then left alone so hand edits survive. Until you edit it, the bot
    advertises a port nothing is listening on:

      sudo mc maintenance-stop
      sudo sed -i 's/^server-port=.*/server-port=<new>/' /srv/minecraft/server/server.properties
      sudo mc start
  EOT
  type        = number
  default     = 25565
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Minecraft port. Narrow this if you know which networks your players are on."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_ssh" {
  description = "Open port 22. Off by default: SSM Session Manager gives you a shell with no open port and no key to lose."
  type        = bool
  default     = false
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name, used only when enable_ssh is true."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to reach port 22 when enable_ssh is true."
  type        = list(string)
  default     = []
}

# --------------------------------------------------------------------------
# Discord
# --------------------------------------------------------------------------

variable "discord_public_key" {
  description = "Public key from the General Information page of the Discord application. Used to verify interaction signatures."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.discord_public_key))
    error_message = "discord_public_key must be the 64-character hex key from the Discord developer portal."
  }
}

variable "discord_webhook_url" {
  description = "Channel webhook the server posts status messages to. Leave empty to disable notifications."
  type        = string
  default     = ""
  sensitive   = true
}

variable "discord_bot_username" {
  description = "Display name on webhook messages."
  type        = string
  default     = "Minecraft Server"
}

variable "discord_notify_player_events" {
  description = <<-EOT
    Whether to post a message when a player joins or leaves.

    Off by default because it is the only notification that fires during play
    rather than around it. A busy evening is a lot of messages, and a server
    people drift in and out of produces more than most channels want. Point the
    webhook at a channel of its own if you turn this on.

    Needs discord_webhook_url -- there is nowhere to post without one, and the
    setting is ignored when it is empty.

    Reports the same joins and leaves the idle shutdown counts, so it doubles
    as a way to see that counting working: if somebody is playing and no join
    was ever posted for them, the server does not know they are there and will
    idle out underneath them.
  EOT
  type        = bool
  default     = false
}

variable "endpoint_type" {
  description = <<-EOT
    How Discord reaches the Lambda.

      function_url - a Lambda function URL. Simpler, free, and nothing else to
                     provision. The default, and right for most accounts.
      api_gateway  - an HTTP API in front of the same Lambda. Use this when a
                     function URL answers every request with 403
                     AccessDeniedException even though its resource policy
                     allows public access -- some accounts refuse to serve
                     public function URLs at all, and no amount of fixing the
                     policy changes that. Free for the first million requests a
                     month for twelve months, then about $1 per million; this
                     stack makes a handful of requests a day.

    Switching changes the URL, so the new one has to be pasted into
    Interactions Endpoint URL on the Discord application page again.
  EOT
  type        = string
  default     = "function_url"

  validation {
    condition     = contains(["function_url", "api_gateway"], var.endpoint_type)
    error_message = "endpoint_type must be function_url or api_gateway."
  }
}

variable "allow_stop_command" {
  description = <<-EOT
    Whether /stop is available at all.

    Set this to false on a shared server and the only way it powers off is by
    going idle: nobody can end a session other people are still in, whether by
    accident or to be a nuisance. The command stays registered in Discord and
    replies explaining how long the server waits when empty, rather than
    failing silently.

    This is enforced in two places. The Lambda refuses the command, and with
    stop disabled Terraform also declines to grant the Lambda the
    ssm:SendCommand permission that carries it out, so the capability is not
    merely hidden.

    An operator can still stop the server from a shell on the instance
    (`sudo mc stop`), which is the intended escape hatch.
  EOT
  type        = bool
  default     = true
}

variable "discord_stop_role_ids" {
  description = <<-EOT
    Discord role IDs allowed to run /stop, when it is enabled. Empty means
    anyone who may use the other commands may also stop the server.

    Use this instead of allow_stop_command = false when you want the people
    running the server to keep the button and everybody else not to have it.
    Roles listed here still have to pass discord_allowed_role_ids, if that is
    set.
  EOT
  type        = list(string)
  default     = []
}

variable "discord_allowed_role_ids" {
  description = "Discord role IDs allowed to run the commands. Empty means everyone in the server may."
  type        = list(string)
  default     = []
}

# --------------------------------------------------------------------------
# Minecraft
# --------------------------------------------------------------------------

variable "accept_minecraft_eula" {
  description = "Set to true to accept the Minecraft EULA (https://aka.ms/MinecraftEULA). The server will not start otherwise."
  type        = bool
  default     = false

  validation {
    condition     = var.accept_minecraft_eula
    error_message = "You must accept the Minecraft EULA by setting accept_minecraft_eula = true."
  }
}

variable "minecraft_version" {
  description = "Minecraft version, or latest for the newest stable release Fabric supports."
  type        = string
  default     = "latest"
}

variable "fabric_loader_version" {
  description = "Fabric loader version, or latest for the newest stable one."
  type        = string
  default     = "latest"
}

variable "server_jar_url" {
  description = "Direct download URL for a server jar. Set this to run Paper, Purpur or vanilla instead of Fabric; it overrides the version settings above."
  type        = string
  default     = ""
}

variable "stop_after_provisioning" {
  description = <<-EOT
    Whether the first boot ends with the instance powered off rather than with
    a server running.

    An EC2 instance cannot be created stopped, so `terraform apply` always boots
    it once -- that boot is what formats the world volume, installs Java and
    fetches Fabric. What it does next is the choice here.

      false - carry on and start the server. The instance is joinable straight
              away, and idles out normally if nobody comes. Convenient, and
              the reason it is the default.
      true  - power off once provisioning is done. `terraform apply` then costs
              about four minutes of instance time and leaves nothing running or
              reachable. The first /start takes ninety seconds like any other.

    Worth turning on if you apply from CI, apply often, or would rather nothing
    ever came up without you asking for it. Only the first boot is affected;
    afterwards the server starts on every boot as usual.
  EOT
  type        = bool
  default     = false
}

variable "idle_timeout_minutes" {
  description = "Minutes with no players before the server saves, backs up and powers the instance off."
  type        = number
  default     = 15
}

variable "max_uptime_hours" {
  description = <<-EOT
    Hard cap on a single session, as a runaway-cost guard. 0 disables it.

    Read from SSM at boot, so raising or lowering it does not reach a session
    that is already running: apply, then /stop and /start before relying on it.
  EOT
  type        = number
  default     = 0
}

variable "uptime_warning_enabled" {
  description = <<-EOT
    Whether to post a Discord message when a session has been running a long
    time. On by default: it ends nothing, interrupts nobody, and covers the one
    way this stack can bill without anybody noticing.

    max_uptime_hours ends a session outright, which is the wrong tool while
    people are still playing. This only speaks up: at uptime_warning_hours, and
    again every time that much longer passes, the server posts how long it has
    been up and how many people are on.

    An empty server already idles out on its own, so what this actually catches
    is the expensive case the idle timer cannot: a session with somebody still
    connected, hours after everyone stopped paying attention to it.

    Without discord_webhook_url there is nowhere to post, and the warning goes to
    the journal instead -- `journalctl -u minecraft`. It still fires, and it is
    not forced off the way discord_notify_player_events is: warnings are hours
    apart rather than one per join, and the line is worth recording on its own.
    A warning that says nobody is online means the idle shutdown has stopped
    working, which is worth knowing whether or not anyone reads a channel.
  EOT
  type        = bool
  default     = true
}

variable "uptime_warning_hours" {
  description = <<-EOT
    Hours between long-session warnings, when uptime_warning_enabled is true.

    The first arrives this many hours after the server starts and another every
    time that much longer passes, so 6 warns at 6, 12, 18 and so on. They stop
    when the server does. Ignored entirely when uptime_warning_enabled is false.
  EOT
  type        = number
  default     = 6

  validation {
    condition     = var.uptime_warning_hours > 0
    error_message = "uptime_warning_hours must be greater than 0. Set uptime_warning_enabled = false to turn the warnings off."
  }
}

variable "shutdown_on_crash" {
  description = <<-EOT
    Power the instance off if the server exits unexpectedly, so a crash cannot
    quietly bill for hours. Turn off while debugging.

    Read from SSM on every boot, so it applies like any other setting: apply,
    then /stop and /start. It is also templated into user-data, for the first
    boot's EXIT trap -- but user_data is in the instance's ignore_changes, so
    editing this never touches a running instance.

    That means turning it ON does not arm it. A session already running keeps
    the value it booted with, so a crash before the next restart still leaves
    the instance up. Apply, then /stop and /start before relying on it.
  EOT
  type        = bool
  default     = true
}

variable "manage_server_properties" {
  description = <<-EOT
    Whether Terraform owns the server.properties settings, or only seeds them.

      false - the default and the original behaviour. server.properties is
              written once, on the first boot, and never touched again. Changing
              server_motd or server_difficulty later does nothing; you edit the
              file on the instance instead. Hand edits are safe forever.
      true  - the settings below are reconciled into server.properties on every
              boot, so changing one is `terraform apply` and a restart, like
              every other setting. Hand edits to those keys are overwritten.

    Only the keys this project sets are touched -- server-port, motd, difficulty,
    gamemode, max-players, view-distance, simulation-distance, white-list,
    enforce-whitelist and online-mode. Anything else in the file, including keys
    a mod reads, is left exactly as it is, and the previous file is kept beside
    it as server.properties.bak.

    Turn this on if you would rather manage the server from terraform.tfvars
    than from a shell on the instance. Leave it off if you tune the server in
    place, or if you use in-game commands like /difficulty that write back to
    the file -- with this on, the next restart would undo them.
  EOT
  type        = bool
  default     = false
}

variable "server_motd" {
  description = "Message shown in the multiplayer server list."
  type        = string
  default     = "An on-demand Minecraft server"
}

variable "server_difficulty" {
  description = "peaceful, easy, normal or hard."
  type        = string
  default     = "normal"

  validation {
    condition     = contains(["peaceful", "easy", "normal", "hard"], var.server_difficulty)
    error_message = "server_difficulty must be one of: peaceful, easy, normal, hard."
  }
}

variable "server_gamemode" {
  description = "survival, creative, adventure or spectator."
  type        = string
  default     = "survival"

  validation {
    condition     = contains(["survival", "creative", "adventure", "spectator"], var.server_gamemode)
    error_message = "server_gamemode must be one of: survival, creative, adventure, spectator."
  }
}

variable "server_max_players" {
  description = "Player slots."
  type        = number
  default     = 10
}

variable "server_view_distance" {
  description = "View distance in chunks. Lowering this is the cheapest way to help a small instance keep up."
  type        = number
  default     = 10
}

variable "server_simulation_distance" {
  description = "Simulation distance in chunks."
  type        = number
  default     = 10
}

variable "server_online_mode" {
  description = "Require Mojang authentication. Leave this true unless you know exactly why you are turning it off."
  type        = bool
  default     = true
}

variable "server_whitelist" {
  description = <<-EOT
    Enable the whitelist.

    Strongly recommended: allowed_cidrs defaults to the whole internet, so
    without this the only thing between your world and a stranger who finds the
    address is Mojang authentication -- which proves who somebody is, not that
    they were invited.

    Turning this on requires at least one name in server_whitelist_players, or
    the apply is refused: an empty enforced whitelist locks out everybody
    including you.
  EOT
  type        = bool
  default     = false
}

# Names in both lists are resolved to real UUIDs when the file is seeded --
# through Mojang for an online-mode server, derived locally for an offline one.
# A name that cannot be resolved is left out and said so in the journal, because
# an entry without a real UUID is one the server silently ignores.
variable "server_ops" {
  description = <<-EOT
    Minecraft usernames to make server operators.

    This is what lets moderation happen in the game rather than in Terraform.
    An operator can run /whitelist add, /whitelist remove, /ban, /kick and /op
    from the chat box, so the config only has to get the first person in --
    everybody after that is somebody else's problem, at the time it comes up,
    without an apply or an SSH session.

    Seeded into ops.json on any boot where that file does not yet exist, so
    setting this after the first deploy still works. Once the file exists the
    in-game commands own it and this value is ignored, which is why an /op
    granted at 2am is not quietly revoked by the next restart.
  EOT
  type        = list(string)
  default     = []
}

variable "server_whitelist_players" {
  description = <<-EOT
    Minecraft usernames to seed the whitelist with.

    Only needs to contain enough people to get started -- realistically you,
    plus anyone in server_ops. Operators add the rest with /whitelist add in
    game.

    Seeded into whitelist.json on any boot where that file does not yet exist,
    exactly like server_ops, and ignored from then on.
  EOT
  type        = list(string)
  default     = []
}

# --------------------------------------------------------------------------
# Backups
# --------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Days to keep backups in S3 before they expire. 0 keeps them forever."
  type        = number
  default     = 30
}

variable "local_backup_keep" {
  description = "Number of recent backups to also keep on the data volume for a fast restore."
  type        = number
  default     = 3
}

variable "restore_from_s3" {
  description = "s3://bucket/key of a backup tarball to unpack on first boot. Use this to migrate an existing world."
  type        = string
  default     = ""
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow terraform destroy to delete the S3 bucket while it still holds
    backups.

    This has to be applied before it counts. force_destroy is read from what
    Terraform already has recorded for the bucket, not from the variables
    passed to the destroy, so setting it here and going straight to
    `terraform destroy` still fails with BucketNotEmpty. Either apply it first
    and then destroy, or skip it and empty the bucket by hand:
    `aws s3 rm s3://<bucket>/ --recursive`.
  EOT
  type        = bool
  default     = false
}

variable "cpu_credits" {
  description = <<-EOT
    Burstable CPU mode for t3/t4g instances.

      standard  - predictable bill. The server may stutter during world
                  generation or when several players explore at once.
      unlimited - smooth under load, at roughly $0.05 per extra vCPU-hour.

    Only applied when the instance type is burstable.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
  }
}
