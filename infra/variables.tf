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
  description = "Palworld release the instance runs; names the instance tag and the SSM parameter"
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

variable "discord_public_key" {
  description = "Public key of the Discord application, used to verify request signatures"
  type        = string
}

variable "game_port" {
  type    = number
  default = 8211
}

variable "query_port" {
  description = "Steam query port the server also binds; a client needs it to finish connecting"
  type        = number
  default     = 27015
}

variable "snapshot_retention_count" {
  description = "Snapshots DLM keeps before deleting the oldest; each extra day of history costs one day of storage"
  type        = number
  default     = 7
}
