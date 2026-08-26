locals {
  arn_prefix   = "arn:${data.aws_partition.current.partition}"
  instance_arn = "${local.arn_prefix}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.server.id}"
}

# --------------------------------------------------------------------------
# Instance role
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Gives Session Manager shell access and the SSM agent permissions the /stop
# command needs to receive its RunShellScript document.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "${local.arn_prefix}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid    = "ReadConfiguration"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "${local.arn_prefix}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*",
    ]
  }

  # The webhook parameter is a SecureString under the AWS-managed aws/ssm key.
  # Its key policy defers to IAM, so ssm:GetParameter alone is not enough --
  # --with-decryption fails with AccessDenied without this. Scoped by ViaService
  # so the role cannot use the key for anything but reading these parameters.
  dynamic "statement" {
    for_each = var.discord_webhook_url != "" ? [1] : []

    content {
      sid       = "DecryptSecureParameters"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  statement {
    sid       = "ReadPayload"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/${local.payload_key}"]
  }

  statement {
    sid    = "WriteBackups"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/backups/*",
    ]
  }

  # Only needed to unpack a migrated world on first boot, and only for the
  # object the operator named.
  dynamic "statement" {
    for_each = var.restore_from_s3 != "" ? [1] : []

    content {
      sid       = "ReadRestoreSource"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${local.arn_prefix}:s3:::${replace(var.restore_from_s3, "s3://", "")}"]
    }
  }

  # Scoped to the one record set the boot script republishes.
  dynamic "statement" {
    for_each = local.use_route53 ? [1] : []

    content {
      sid       = "UpdateDnsRecord"
      effect    = "Allow"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["${local.arn_prefix}:route53:::hostedzone/${var.route53_zone_id}"]

      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = [lower(local.record_name)]
      }

      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsRecordTypes"
        values   = ["A"]
      }
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${local.name}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# --------------------------------------------------------------------------
# Lambda role
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-discord"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  # DescribeInstances does not support resource-level permissions, so this one
  # cannot be narrowed further than the account.
  statement {
    sid       = "ReadInstanceState"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "StartServer"
    effect    = "Allow"
    actions   = ["ec2:StartInstances"]
    resources = [local.instance_arn]
  }

  # /stop runs the on-instance script rather than calling ec2:StopInstances, so
  # the world is saved and backed up first. Deliberately no ec2:StopInstances
  # here: there is no safe path that skips the save.
  statement {
    sid       = "RequestGracefulStop"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [
      local.instance_arn,
      "${local.arn_prefix}:ssm:${var.aws_region}::document/AWS-RunShellScript",
    ]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name}-discord"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}
