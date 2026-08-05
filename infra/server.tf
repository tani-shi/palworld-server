data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

// Rules live in standalone resources so the ingress the Discord bot adds at
// runtime is not reverted on the next apply.
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

// A player gets the game port and the Steam query port: joining by address uses
// the former, joining through the server list queries the latter.
resource "aws_vpc_security_group_ingress_rule" "game" {
  for_each = {
    for pair in setproduct(var.player_cidrs, [var.game_port, var.query_port]) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.server.id
  description       = "palworld player"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_cidrs)

  security_group_id = aws_security_group.server.id
  description       = "ssh"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "community_browser" {
  count = var.publish_to_community_browser ? 1 : 0

  security_group_id = aws_security_group.server.id
  description       = "steam query"
  ip_protocol       = "udp"
  from_port         = var.query_port
  to_port           = var.query_port
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.server.id]
  iam_instance_profile        = aws_iam_instance_profile.server.name
  key_name                    = var.key_name
  user_data                   = local.user_data
  user_data_replace_on_change = false

  // Keeping the root volume after termination would strand it: a replacement
  // instance builds a fresh one and never reads the old saves. Continuity comes
  // from the S3 archive that user_data restores instead.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "palworld-server-${var.server_version}" }
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
    backup_bucket     = aws_s3_bucket.saves.bucket
    server_version    = var.server_version
    maintenance_time  = var.maintenance_time
    update_on_boot    = var.update_on_boot
  })
}
