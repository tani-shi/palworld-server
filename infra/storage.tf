// Run Command truncates StandardOutputContent at 24,000 characters. The
// game-data response passes that with a single player online, so every REST
// API call writes its output here and the caller reads it back from S3.
resource "aws_s3_bucket" "command_output" {
  bucket_prefix = "${var.project}-command-output-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "command_output" {
  bucket                  = aws_s3_bucket.command_output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

// Each object is read once by the caller that produced it and never again.
resource "aws_s3_bucket_lifecycle_configuration" "command_output" {
  bucket = aws_s3_bucket.command_output.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
