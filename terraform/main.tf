# Shared lookups, derived values and the configuration handed to the instance.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --------------------------------------------------------------------------
# Instance type -> architecture -> AMI
#
# Looked up rather than hard-coded so switching between t4g (arm64) and t3
# (x86_64) in one variable does the right thing.
# --------------------------------------------------------------------------

data "aws_ec2_instance_type" "server" {
  instance_type = var.instance_type
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.architecture}"
}

# --------------------------------------------------------------------------
# Networking lookups
# --------------------------------------------------------------------------

data "aws_vpc" "selected" {
  id      = var.vpc_id != "" ? var.vpc_id : null
  default = var.vpc_id != "" ? null : true
}

data "aws_subnets" "public" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

locals {
  name = var.project_name

  architecture = contains(data.aws_ec2_instance_type.server.supported_architectures, "arm64") ? "arm64" : "x86_64"

  # try() falls through to a string that names the fix, rather than to an
  # opaque empty-list index error.
  subnet_id = var.subnet_id != "" ? var.subnet_id : try(
    data.aws_subnets.public[0].ids[0],
    "no-public-subnet-found--set-subnet_id-explicitly"
  )

  # Leave room for the OS, the JVM's own off-heap memory and the page cache:
  # a full gigabyte where there is memory to spare, and 40% of it below that.
  # The old "always reserve 1 GB" rule handed a 1 GB instance a 1 GB heap,
  # which is every byte the machine has.
  instance_memory_mb = data.aws_ec2_instance_type.server.memory_size
  os_reserve_mb      = local.instance_memory_mb >= 2048 ? 1024 : floor(local.instance_memory_mb * 0.4)
  auto_heap_mb       = max(512, local.instance_memory_mb - local.os_reserve_mb)
  heap_mb            = var.java_heap_mb > 0 ? var.java_heap_mb : local.auto_heap_mb

  use_api_gateway = var.endpoint_type == "api_gateway"

  # Whichever endpoint was built. one() yields null for the branch that was not
  # created, and coalesce skips nulls, so exactly one of these survives.
  interactions_endpoint_url = coalesce(
    one(aws_apigatewayv2_stage.discord[*].invoke_url),
    one(aws_lambda_function_url.discord[*].function_url),
  )

  use_route53    = var.addressing_mode == "route53"
  use_elastic_ip = var.addressing_mode == "elastic_ip"

  # A trailing dot is how Route 53 stores names; strip it for anything a human
  # or a Minecraft client will read.
  record_name = trimsuffix(var.route53_record_name, ".")

  # one() yields null rather than erroring when the EIP is not created, which
  # aws_eip.server[0] would. coalesce() is not usable here: it rejects "" as
  # unset and so would fail outright in "none" mode.
  eip_address    = one(aws_eip.server[*].public_ip)
  static_address = local.use_route53 ? local.record_name : (local.eip_address != null ? local.eip_address : "")

  # Empty in "none" mode, which tells the Lambda to report whatever public IP
  # the instance happens to have this session.
  connect_address = local.static_address

  ssm_prefix         = "/${var.project_name}"
  config_param_name  = "${local.ssm_prefix}/config"
  webhook_param_name = "${local.ssm_prefix}/discord-webhook-url"

  # Code lives on the root volume; the world lives on the data volume. They
  # must not overlap, or mounting the data volume would hide the scripts.
  install_dir = "/opt/minecraft"
  data_mount  = "/srv/minecraft"
  server_dir  = "/srv/minecraft/server"

  # Requested device name. Nitro instances rename it, which is why the
  # bootstrap script resolves the volume by ID and falls back to this.
  data_device = "/dev/sdf"

  payload_key = "payload/server.zip"

  # --------------------------------------------------------------------------
  # Everything the instance scripts read. Published to SSM and re-read on every
  # boot, so changing a value here takes effect on the next start with no
  # instance replacement.
  # --------------------------------------------------------------------------
  instance_config = {
    AWS_REGION = var.aws_region

    ADDRESSING_MODE     = var.addressing_mode
    STATIC_ADDRESS      = local.static_address
    ROUTE53_ZONE_ID     = local.use_route53 ? var.route53_zone_id : ""
    ROUTE53_RECORD_NAME = local.use_route53 ? local.record_name : ""
    ROUTE53_TTL         = tostring(var.route53_ttl)

    DISCORD_WEBHOOK_SSM_PARAM = var.discord_webhook_url != "" ? local.webhook_param_name : ""
    DISCORD_USERNAME          = var.discord_bot_username

    # Gated on the webhook existing: without one every join would spawn a
    # notify.sh that can only write to the journal, and joins are frequent.
    NOTIFY_PLAYER_EVENTS = var.discord_webhook_url != "" ? tostring(var.discord_notify_player_events) : "false"

    DATA_MOUNT     = local.data_mount
    DATA_DEVICE    = local.data_device
    DATA_VOLUME_ID = aws_ebs_volume.data.id
    SERVER_DIR     = local.server_dir
    SERVER_JAR     = "server.jar"
    MC_USER        = "minecraft"
    INSTALL_DIR    = local.install_dir
    JAVA_PACKAGE   = var.java_package
    JAVA_HEAP_MB   = tostring(local.heap_mb)
    NOTIFY_SCRIPT  = "/opt/minecraft/bin/notify.sh"

    ACCEPT_EULA           = tostring(var.accept_minecraft_eula)
    MINECRAFT_VERSION     = var.minecraft_version
    FABRIC_LOADER_VERSION = var.fabric_loader_version
    SERVER_JAR_URL        = var.server_jar_url

    IDLE_TIMEOUT_MINUTES = tostring(var.idle_timeout_minutes)
    STOP_AFTER_PROVISION = tostring(var.stop_after_provisioning)
    MAX_UPTIME_HOURS     = tostring(var.max_uptime_hours)

    # One value rather than two: the boolean only decides whether there is
    # an interval at all, and 0 already means "no warnings" to the script.
    UPTIME_WARNING_HOURS = var.uptime_warning_enabled ? tostring(var.uptime_warning_hours) : "0"
    SHUTDOWN_ON_CRASH    = tostring(var.shutdown_on_crash)
    STOP_TIMEOUT_SECONDS = "120"

    # Two guards with no variable of their own, published here so they can be
    # tuned without editing the scripts.
    #
    # The ready line is the only thing that arms the idle countdown, so a
    # server that never prints it -- a mod hanging in init, a world that will
    # not load -- would otherwise sit there with nobody on it and no timer
    # running. Generous, because a first boot generates the spawn area.
    STARTUP_TIMEOUT_MINUTES = "30"

    # systemd kills the whole stop sequence at TimeoutStopSec (300s). The
    # backup that runs before the power-off has no natural ceiling, so it is
    # bounded well inside that budget: losing one backup is recoverable,
    # missing the power-off is billed by the hour.
    STOP_BACKUP_TIMEOUT_SECONDS = "180"

    SERVER_PORT                = tostring(var.server_port)
    SERVER_MOTD                = var.server_motd
    SERVER_DIFFICULTY          = var.server_difficulty
    SERVER_GAMEMODE            = var.server_gamemode
    SERVER_MAX_PLAYERS         = tostring(var.server_max_players)
    SERVER_VIEW_DISTANCE       = tostring(var.server_view_distance)
    SERVER_SIMULATION_DISTANCE = tostring(var.server_simulation_distance)
    SERVER_ONLINE_MODE         = tostring(var.server_online_mode)
    SERVER_WHITELIST           = tostring(var.server_whitelist)
    SERVER_OPS                 = join(",", var.server_ops)
    SERVER_WHITELIST_PLAYERS   = join(",", var.server_whitelist_players)
    SERVER_MODS                = join(",", var.server_mods)

    BACKUP_BUCKET     = aws_s3_bucket.data.id
    BACKUP_PREFIX     = "backups"
    LOCAL_BACKUP_KEEP = tostring(var.local_backup_keep)
    RESTORE_FROM_S3   = var.restore_from_s3

    PAYLOAD_BUCKET   = aws_s3_bucket.data.id
    PAYLOAD_KEY      = local.payload_key
    CONFIG_SSM_PARAM = local.config_param_name
  }

  # KEY="value" lines, readable both by `source` in bash and by systemd
  # EnvironmentFile.
  # Escape in this order: flatten newlines, which would otherwise split one
  # setting across two lines and corrupt the file; then backslashes; then
  # quotes, so the backslash added for a quote is not escaped a second time.
  # common.sh parses this without evaluating it, so a value cannot execute.
  config_env = join("\n", [
    for key in sort(keys(local.instance_config)) :
    format("%s=\"%s\"", key, replace(replace(replace(
      local.instance_config[key], "/[\r\n]+/", " "
    ), "\\", "\\\\"), "\"", "\\\""))
  ])

  # The minimum needed to reach AWS and fetch everything else. Written once by
  # user-data; the rest comes from SSM on every boot.
  bootstrap_env = join("\n", [
    format("AWS_REGION=\"%s\"", var.aws_region),
    format("CONFIG_SSM_PARAM=\"%s\"", local.config_param_name),
    format("PAYLOAD_BUCKET=\"%s\"", aws_s3_bucket.data.id),
    format("PAYLOAD_KEY=\"%s\"", local.payload_key),
  ])
}

# --------------------------------------------------------------------------
# Guard rails that variable validation cannot express, because they span
# several variables.
# --------------------------------------------------------------------------

resource "terraform_data" "preconditions" {
  lifecycle {
    precondition {
      condition     = !local.use_route53 || (var.route53_zone_id != "" && var.route53_record_name != "")
      error_message = "addressing_mode = \"route53\" requires both route53_zone_id and route53_record_name."
    }

    precondition {
      condition     = !var.enable_ssh || length(var.ssh_allowed_cidrs) > 0
      error_message = "enable_ssh = true requires ssh_allowed_cidrs. Leave SSH off and use SSM Session Manager instead."
    }

    precondition {
      condition     = var.restore_from_s3 == "" || startswith(var.restore_from_s3, "s3://")
      error_message = "restore_from_s3 must be an s3:// URI."
    }

    precondition {
      condition     = !var.server_whitelist || length(var.server_whitelist_players) > 0
      error_message = "server_whitelist = true with an empty server_whitelist_players locks everyone out, including you. Add at least your own Minecraft username; you can add the rest in-game with /whitelist add."
    }
  }
}
