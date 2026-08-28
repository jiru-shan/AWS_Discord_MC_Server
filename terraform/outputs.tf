output "discord_interactions_endpoint_url" {
  description = "Paste this into Interactions Endpoint URL on the Discord application General Information page."
  value       = local.interactions_endpoint_url
}

output "connect_address" {
  description = "What players type into the Minecraft multiplayer screen."
  value = local.connect_address != "" ? (
    var.server_port == 25565 ? local.connect_address : "${local.connect_address}:${var.server_port}"
  ) : "(no stable address: addressing_mode is \"none\", so use /status in Discord each session)"
}

output "instance_id" {
  description = "EC2 instance running the server."
  value       = aws_instance.server.id
}

output "elastic_ip" {
  description = "Static public IP, when addressing_mode is elastic_ip."
  value       = local.eip_address
}

output "backup_bucket" {
  description = "S3 bucket holding world backups and the script payload."
  value       = aws_s3_bucket.data.id
}

output "shell_command" {
  description = "Open a root shell on the instance. No SSH key and no open port needed."
  value       = "aws ssm start-session --target ${aws_instance.server.id} --region ${var.aws_region}"
}

output "logs_command" {
  description = "Tail the Lambda logs while debugging the Discord endpoint."
  value       = "aws logs tail ${aws_cloudwatch_log_group.lambda.name} --follow --region ${var.aws_region}"
}

output "next_steps" {
  description = "What to do after the first apply."
  value       = <<-EOT

    1. Discord developer portal -> your application -> General Information
       Interactions Endpoint URL:
         ${local.interactions_endpoint_url}
       Discord sends a signed test request when you save. If it saves cleanly,
       the endpoint is live.

    2. Register the slash commands:
         python scripts/register_commands.py

    3. In Discord, run /start. First boot installs Java and downloads the
       server, so allow around five minutes; later boots take about ninety
       seconds.

    Watch the first boot with:
      aws ssm start-session --target ${aws_instance.server.id} --region ${var.aws_region}
      sudo tail -f /var/log/cloud-init-output.log
  EOT
}
