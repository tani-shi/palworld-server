output "aws_region" {
  description = "Pass to the aws CLI: the default profile's region is unrelated to where this stack lives"
  value       = var.aws_region
}

output "instance_id" {
  value = aws_instance.server.id
}

output "root_volume_id" {
  description = "The volume that holds the world; the target of a snapshot restore"
  value       = aws_instance.server.root_block_device[0].volume_id
}

output "security_group_id" {
  value = aws_security_group.server.id
}

output "server_address" {
  value = "${aws_eip.server.public_ip}:${var.game_port}"
}

// The Makefile opens both ports for an address, so it needs them separately --
// server_address carries only the game port.
output "game_port" {
  value = var.game_port
}

output "query_port" {
  value = var.query_port
}

output "bot_webhook_url" {
  description = "Set as the Interactions Endpoint URL of the Discord application"
  value       = one(aws_lambda_function_url.bot_webhook[*].function_url)
}

output "server_secrets_parameter" {
  description = "SSM parameter holding the admin password; read it with aws ssm get-parameter --with-decryption"
  value       = aws_ssm_parameter.server_secrets.name
}
