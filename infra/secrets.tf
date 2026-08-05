// Passwords travel through SSM rather than user_data: user_data is readable by
// anything that can reach the instance metadata service.
resource "aws_ssm_parameter" "server_secrets" {
  name = "/${var.project}/${var.server_version}/server_secrets"
  type = "SecureString"
  value = jsonencode({
    admin_password  = local.admin_password
    server_password = var.server_password
  })
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

locals {
  admin_password = coalesce(var.admin_password, random_password.admin.result)
}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}
