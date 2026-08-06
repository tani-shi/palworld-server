// These are the only copy of the world outside the instance's own disk. DLM
// takes them so that rotation and expiry are AWS behaviour, and so that a
// restore follows the documented snapshot/volume/attach path.
data "aws_iam_policy_document" "assume_dlm" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project}-dlm"
  assume_role_policy = data.aws_iam_policy_document.assume_dlm.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Daily snapshots of the Palworld instance"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]
    target_tags    = { Name = "palworld-server-${var.server_version}" }

    schedule {
      name = "daily"

      // UTC. DLM snapshots attached volumes whether the instance runs or not, so
      // the hour only decides how much play a restore can roll back.
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["19:00"]
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      copy_tags = true
    }
  }
}
