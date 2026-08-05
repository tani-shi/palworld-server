output "instance_id" {
  value = aws_instance.server.id
}

output "instance_name" {
  description = "Tag the Discord bot resolves; set DEFAULT_VERSION in the bot env to var.server_version"
  value       = aws_instance.server.tags["Name"]
}

output "security_group_id" {
  description = "Set as AWS_SECURITY_GROUP_ID for the bot's register command"
  value       = aws_security_group.server.id
}

output "server_address" {
  value = "${aws_eip.server.public_ip}:${var.game_port}"
}

output "bot_webhook_url" {
  description = "Set as the Interactions Endpoint URL of the Discord application"
  value       = one(aws_lambda_function_url.bot_webhook[*].function_url)
}

output "server_secrets_parameter" {
  description = "SSM parameter holding the admin password; read it with aws ssm get-parameter --with-decryption"
  value       = aws_ssm_parameter.server_secrets.name
}

output "backup_bucket" {
  value = aws_s3_bucket.saves.bucket
}
