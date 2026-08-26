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

    Rough guide: t4g.small (2 GB) for 2-3 players on a light world,
    t4g.medium (4 GB) for up to about 8, t4g.large (8 GB) for a modpack.
  EOT
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_gb" {
  description = "Root volume size. Holds the OS and the scripts only; the world lives on the data volume."
  type        = number
  default     = 12
}

variable "data_volume_gb" {
  description = "Persistent volume for the world, backups and mods. Survives instance replacement."
  type        = number
  default     = 20
}

variable "java_heap_mb" {
  description = "Java heap size in MB. 0 sizes it from the memory of the instance, leaving 1 GB for the OS."
  type        = number
  default     = 0
}

variable "java_package" {
  description = "JDK package to install. Minecraft 1.20.5 and later need Java 21."
  type        = string
  default     = "java-21-amazon-corretto-headless"
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
}

variable "route53_ttl" {
  description = "TTL for the A record. Keep it short so a restart propagates quickly."
  type        = number
  default     = 30
}

variable "server_port" {
  description = "Port the server listens on."
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

variable "idle_timeout_minutes" {
  description = "Minutes with no players before the server saves, backs up and powers the instance off."
  type        = number
  default     = 15
}

variable "max_uptime_hours" {
  description = "Hard cap on a single session, as a runaway-cost guard. 0 disables it."
  type        = number
  default     = 0
}

variable "shutdown_on_crash" {
  description = "Power the instance off if the server exits unexpectedly, so a crash cannot quietly bill for hours. Turn off while debugging."
  type        = bool
  default     = true
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
  description = "Enable the whitelist. Strongly recommended when the port is open to the internet."
  type        = bool
  default     = false
}

variable "server_ops" {
  description = "Minecraft usernames to make operators on a fresh install. Ignored once ops.json exists."
  type        = list(string)
  default     = []
}

variable "server_whitelist_players" {
  description = "Minecraft usernames to seed the whitelist with on a fresh install."
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
  description = "Allow terraform destroy to delete the S3 bucket while it still holds backups."
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
