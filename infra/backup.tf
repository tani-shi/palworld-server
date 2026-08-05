data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "saves" {
  bucket = "${var.project}-saves-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "saves" {
  bucket                  = aws_s3_bucket.saves.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "saves" {
  bucket = aws_s3_bucket.saves.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "saves" {
  bucket = aws_s3_bucket.saves.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "saves" {
  bucket = aws_s3_bucket.saves.id

  rule {
    id     = "expire-archives"
    status = "Enabled"

    filter {
      prefix = "saves/"
    }

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
  }
}
