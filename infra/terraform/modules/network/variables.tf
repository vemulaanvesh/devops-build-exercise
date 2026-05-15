variable "name_prefix" {
  description = "Prefix for resource names, e.g. 'agent-prod'."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread subnets across (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_gateway_count" {
  description = <<-EOT
    NAT Gateways to provision. 0 = no public egress, rely on VPC endpoints.
    Recommended for prod with strict egress posture.
  EOT
  type        = number
  default     = 0
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 443."
  type        = list(string)
  # Internal-only by default. Override for an API-Gateway-fronted edge.
  default = ["10.0.0.0/8"]
}

variable "ecs_container_port" {
  description = "Container port the ECS tasks listen on."
  type        = number
  default     = 8080
}

variable "tags" {
  description = "Common tags to apply."
  type        = map(string)
  default     = {}
}
