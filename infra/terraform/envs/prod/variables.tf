variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "agent-prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "nat_gateway_count" {
  description = "0 = endpoint-only egress (prod default). Bump to 2 if you need ad-hoc internet egress."
  type        = number
  default     = 0
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the internal ALB."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the ALB. Must be in the same region."
  type        = string
}

variable "image_uri" {
  description = "Container image URI from ECR, pinned by digest or git SHA."
  type        = string
}

variable "docs_bucket_name" {
  type    = string
  default = "saaf-agent-prod-docs"
}

variable "audit_bucket_name" {
  type    = string
  default = "saaf-agent-prod-audit"
}

variable "llm_provider" {
  description = "anthropic | bedrock | mock"
  type        = string
  default     = "bedrock"
}

variable "llm_model" {
  type    = string
  default = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "bedrock_model_arns" {
  description = "ARNs of Bedrock model IDs the task may invoke."
  type        = list(string)
  default     = []
}

variable "ses_from_address" {
  type    = string
  default = "loans@saaffinance.com"
}

variable "ses_identity_arn" {
  description = "ARN of the SES verified domain or email identity."
  type        = string
}

variable "otel_otlp_endpoint" {
  description = "OTLP endpoint for traces. Empty disables export."
  type        = string
  default     = ""
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 20
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  type    = number
  default = 90
}
