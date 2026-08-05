variable "aws_region" {
  description = "Region to deploy the server into"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Tag/name prefix for every resource"
  type        = string
  default     = "palworld"
}

variable "server_version" {
  description = "Palworld release the instance runs; the bot resolves instances by the tag palworld-server-<server_version>"
  type        = string
  default     = "1.0"
}

variable "instance_type" {
  description = "4 vCPU / 16 GiB matches the official recommendation; m7i-flex avoids the burst-credit stalls of t3"
  type        = string
  default     = "m7i-flex.xlarge"
}

variable "root_volume_size" {
  description = "GiB of gp3 root storage (server files are ~15 GiB and grow on every update)"
  type        = number
  default     = 60
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "player_cidrs" {
  description = "CIDRs allowed to reach the game port; the Discord bot appends to this rule at runtime"
  type        = list(string)
  default     = []
}

variable "ssh_cidrs" {
  description = "CIDRs allowed to SSH in; leave empty and use SSM Session Manager instead"
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "EC2 key pair for SSH; null disables SSH key injection"
  type        = string
  default     = null
}

variable "publish_to_community_browser" {
  description = "Open 27015/udp so the server is listed in the in-game community browser"
  type        = bool
  default     = false
}

variable "server_name" {
  type    = string
  default = "Palworld Server"
}

variable "server_description" {
  type    = string
  default = "Managed by Terraform"
}

variable "max_players" {
  type    = number
  default = 16
}

variable "admin_password" {
  description = "Password that grants admin rights in game; null generates one into SSM"
  type        = string
  sensitive   = true
  default     = null
}

variable "server_password" {
  description = "Join password; empty string leaves the security group as the only gate"
  type        = string
  sensitive   = true
  default     = ""
}

variable "game_port" {
  type    = number
  default = 8211
}

variable "maintenance_time" {
  description = "systemd OnCalendar expression for the nightly backup + restart that flushes the server's memory growth"
  type        = string
  default     = "*-*-* 05:00:00"
}

variable "backup_retention_days" {
  description = "Days before save archives in S3 expire"
  type        = number
  default     = 30
}

variable "update_on_boot" {
  description = "Run steamcmd app_update before each service start so a bot-driven start picks up patches"
  type        = bool
  default     = true
}
