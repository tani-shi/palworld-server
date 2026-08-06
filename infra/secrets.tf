// Not passed through user_data, which anything reaching the instance metadata
// service can read. This parameter is also the only readable copy of the value
// provisioning wrote into PalWorldSettings.ini.
resource "aws_ssm_parameter" "server_secrets" {
  name  = "/${var.project}/${var.server_version}/server_secrets"
  type  = "SecureString"
  value = jsonencode({ admin_password = random_password.admin.result })
}

// An empty AdminPassword makes the in-game moderation commands unreachable, so
// one is generated rather than required as input.
resource "random_password" "admin" {
  length = 32
  // PalWorldSettings.ini packs every option into a single comma-separated line
  // of quoted values, so punctuation in the password breaks the parser.
  special = false
}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}
