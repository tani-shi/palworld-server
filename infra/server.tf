data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

// Terraform declares no ingress at all: every player address arrives through
// the bot's `register` at runtime. A second, Terraform-managed list of the same
// rules would only be another place for the allowlist to disagree with itself.
resource "aws_security_group" "server" {
  name        = "${var.project}-server"
  description = "Palworld dedicated server"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.server.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.server.name
  user_data              = local.user_data

  // prevent_destroy below only binds Terraform; this is what stops a terminate
  // issued from the console or the CLI.
  disable_api_termination = true

  // The world lives here and nowhere else, so the volume outlives the instance.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = false
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "palworld-server-${var.server_version}" }

  // This instance's disk holds the only copy of the world, so nothing routine
  // may replace it. A moved AMI id and an edited user_data both would, and
  // neither is worth the world -- rebuilding is a deliberate operation that
  // starts from a snapshot.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, user_data]
  }
}

resource "aws_eip" "server" {
  instance = aws_instance.server.id
  domain   = "vpc"

  tags = { Name = "palworld-server-${var.server_version}" }
}

locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region        = var.aws_region
    steam_app_id      = 2394010
    server_name       = var.server_name
    server_desc       = var.server_description
    max_players       = var.max_players
    game_port         = var.game_port
    secrets_parameter = aws_ssm_parameter.server_secrets.name
  })
}
