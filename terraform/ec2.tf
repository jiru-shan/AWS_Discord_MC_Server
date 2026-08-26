resource "aws_instance" "server" {
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type
  subnet_id     = local.subnet_id

  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.enable_ssh && var.ssh_key_name != "" ? var.ssh_key_name : null

  associate_public_ip_address = true

  # The whole design depends on this: `shutdown -h` from inside the instance
  # must stop it, not terminate it, or the world would be destroyed nightly.
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only. The scripts request a token before reading metadata.
    http_tokens = "required"
  }

  # Burstable families only; setting this on other types is an error.
  dynamic "credit_specification" {
    for_each = data.aws_ec2_instance_type.server.burstable_performance_supported ? [1] : []

    content {
      cpu_credits = var.cpu_credits
    }
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    bootstrap_env     = local.bootstrap_env
    payload_bucket    = aws_s3_bucket.data.id
    payload_key       = local.payload_key
    region            = var.aws_region
    shutdown_on_crash = tostring(var.shutdown_on_crash)
  })

  # cloud-init runs user-data once, at first boot, so a later change here has no
  # effect on a live instance and must not silently rebuild it. Configuration
  # and script updates travel through SSM and S3 instead, and land on the next
  # boot. Set this to true only when you deliberately want a clean rebuild.
  user_data_replace_on_change = false

  # The instance reads both of these during its first boot.
  depends_on = [
    aws_ssm_parameter.config,
    aws_s3_object.payload,
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm_core,
  ]

  tags = {
    Name = "${local.name}-server"
  }

  lifecycle {
    # The AMI parameter tracks the latest Amazon Linux release, which would
    # otherwise propose replacing the instance on every apply.
    ignore_changes = [ami]
  }
}

# --------------------------------------------------------------------------
# Elastic IP
#
# Only created in elastic_ip mode. Keeping it associated while the instance is
# stopped is what makes the address stable across sessions, and is also the
# only part of this stack that bills while nobody is playing.
# --------------------------------------------------------------------------

resource "aws_eip" "server" {
  count = local.use_elastic_ip ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${local.name}-server"
  }
}

resource "aws_eip_association" "server" {
  count = local.use_elastic_ip ? 1 : 0

  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server[0].id
}
