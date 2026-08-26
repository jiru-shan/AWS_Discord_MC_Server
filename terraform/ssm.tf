# The instance reads its whole configuration from here on every boot, which is
# what lets `terraform apply` change the idle timeout, MOTD or Minecraft version
# without rebuilding the box.

resource "aws_ssm_parameter" "config" {
  name        = local.config_param_name
  description = "Environment file for the ${var.project_name} server scripts"
  type        = "String"
  tier        = length(local.config_env) > 4096 ? "Advanced" : "Standard"
  value       = local.config_env
}

# The webhook URL is a bearer credential: anyone holding it can post to the
# channel. It is kept encrypted and out of both Terraform outputs and the
# instance configuration, which only carries the parameter name.
resource "aws_ssm_parameter" "discord_webhook" {
  count = var.discord_webhook_url != "" ? 1 : 0

  name        = local.webhook_param_name
  description = "Discord webhook the ${var.project_name} server posts status to"
  type        = "SecureString"
  value       = var.discord_webhook_url
}
