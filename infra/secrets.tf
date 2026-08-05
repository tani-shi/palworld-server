// The password travels through SSM rather than user_data: user_data is readable
// by anything that can reach the instance metadata service. It stays in SSM
// afterwards as the only readable copy -- the value provisioning baked into
// PalWorldSettings.ini cannot be recovered from anywhere else.
resource "aws_ssm_parameter" "server_secrets" {
  name  = "/${var.project}/${var.server_version}/server_secrets"
  type  = "SecureString"
  value = jsonencode({ admin_password = random_password.admin.result })
}

// An empty AdminPassword leaves nobody able to claim admin rights in game, so
// the moderation commands become unreachable. Generating one keeps them
// available without asking the operator to invent a password.
resource "random_password" "admin" {
  length = 32
  // PalWorldSettings.ini packs every option into a single comma-separated line
  // of quoted values, so punctuation in the password breaks the parser.
  special = false
}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}
