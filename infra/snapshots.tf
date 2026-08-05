// Snapshots are the only copy of the world outside the instance's own disk.
// They are taken by DLM rather than by a script on the box: rotation, retention
// and error reporting are then AWS's behaviour, not ours to get right, and a
// restore is the documented "snapshot -> volume -> attach" path rather than the
// unpacking of an archive whose format we invented.
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

      // DLM reads times as UTC, and it snapshots attached volumes whether the
      // instance runs or not, so the hour only decides how much play a restore
      // can roll back -- not whether a snapshot happens at all.
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
