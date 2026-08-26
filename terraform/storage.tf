# One private bucket holds both the script payload the instance downloads and
# the world backups it uploads. Splitting them across two buckets would double
# the IAM surface for no benefit.

resource "aws_s3_bucket" "data" {
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  # Backups are the only thing here that is not reproducible, so destroying the
  # bucket takes an explicit opt-in.
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning is deliberately left off: backups are already timestamped and
# immutable, so versions would only add cost, and the payload object is meant to
# be overwritten in place.

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  # Expire old backups rather than making people prune them by hand.
  dynamic "rule" {
    for_each = var.backup_retention_days > 0 ? [1] : []

    content {
      id     = "expire-backups"
      status = "Enabled"

      filter {
        prefix = "backups/"
      }

      expiration {
        days = var.backup_retention_days
      }
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --------------------------------------------------------------------------
# Script payload
#
# Re-zipped on every plan, so editing anything under server/ and running
# `terraform apply` publishes it. The instance picks it up on its next boot, or
# immediately with `mc update`.
# --------------------------------------------------------------------------

data "archive_file" "payload" {
  type        = "zip"
  source_dir  = "${path.module}/../server"
  output_path = "${path.module}/.build/server-payload.zip"
}

resource "aws_s3_object" "payload" {
  bucket = aws_s3_bucket.data.id
  key    = local.payload_key
  source = data.archive_file.payload.output_path
  etag   = data.archive_file.payload.output_md5
}

# --------------------------------------------------------------------------
# Persistent world storage
#
# Separate from the root volume so the world outlives the instance: an AMI
# refresh or an instance type change replaces the box without touching this.
# --------------------------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name}-data"
  }

  # Note: `terraform destroy` deletes this volume and the world on it. Take a
  # backup first -- `mc backup` on the instance, or copy the newest object out
  # of the backups/ prefix in S3.
}

resource "aws_volume_attachment" "data" {
  device_name = local.data_device
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.server.id

  # The instance is powered off most of the time; do not wait for a running
  # instance to acknowledge the detach during destroy.
  stop_instance_before_detaching = true
}
