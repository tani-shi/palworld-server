data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "${var.project}-server"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

// The instance reads the admin password to provision itself and to authenticate
// its own idle check, and stops itself when that check finds nobody playing.
data "aws_iam_policy_document" "server" {
  statement {
    sid       = "ReadServerSecrets"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.server_secrets.arn]
  }

  statement {
    sid       = "DecryptServerSecrets"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }

  // Narrowed to this one instance: the role is reachable from anything running
  // on the box, and a wildcard would let it stop the rest of the account.
  statement {
    sid       = "StopWhenEmpty"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.server.id}"]
  }
}

resource "aws_iam_role_policy" "server" {
  name   = "${var.project}-server"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.project}-server"
  role = aws_iam_role.server.name
}
