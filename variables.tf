variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Prefix for resource names (avoid collisions on re-apply)"
  type        = string
  default     = "soa05-xray"
}

variable "instance_type" {
  description = "EC2 instance type (t3.micro is enough for X-Ray verification)"
  type        = string
  default     = "t3.micro"
}

variable "alarm_email" {
  description = "Optional email for SNS alarm notifications. Empty = no subscription (alarm still transitions; measure via state history)."
  type        = string
  default     = ""
}

variable "auto_stop_minutes" {
  description = "Safety net: stop the instance after N minutes to cap forgotten-destroy cost"
  type        = number
  default     = 1440
}
