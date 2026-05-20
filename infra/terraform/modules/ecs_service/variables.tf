variable "name_prefix" {
  description = "Cluster and service name prefix."
  type        = string
}

variable "env" {
  description = "Environment label."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type    = list(string)
  default = []
}

variable "alb_security_group_id" {
  type = string
}

variable "ecs_security_group_id" {
  type = string
}

variable "alb_internal" {
  description = "Internal ALB. True in default design; false if fronted by direct internet."
  type        = bool
  default     = true
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener."
  type        = string
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket name for ALB access logs. Empty disables access logs."
  type        = string
  default     = ""
}

variable "alb_access_logs_prefix" {
  description = "S3 key prefix under which ALB writes access logs."
  type        = string
  default     = "alb"
}

variable "image_uri" {
  description = "Container image, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/agent:<sha>."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "task_cpu" {
  description = "Fargate task CPU units. 512 = 0.5 vCPU."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. ARM64 (Graviton) is ~20% cheaper."
  type        = string
  default     = "ARM64"
}

variable "desired_count" {
  description = "Initial desired count (autoscaling takes over after first apply)."
  type        = number
  default     = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 20
}

variable "requests_per_target_target" {
  description = "Target ALB RequestCountPerTarget per minute."
  type        = number
  default     = 600
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the service log group."
  type        = number
  default     = 90
}

variable "kms_key_arn_logs" {
  description = "KMS key ARN for the service log group encryption."
  type        = string
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN holding DATABASE_URL under key 'database_url'."
  type        = string
}

variable "anthropic_secret_arn" {
  description = "Secrets Manager ARN holding the Anthropic API key under 'api_key'."
  type        = string
}

variable "secret_arns" {
  description = "All secret ARNs the execution role may read."
  type        = list(string)
}

variable "docs_bucket_name" {
  type = string
}

variable "docs_bucket_arn" {
  type = string
}

variable "audit_bucket_arn" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "kms_key_arn_secrets" {
  type = string
}

variable "kms_key_arn_docs" {
  type = string
}

variable "kms_key_arn_audit" {
  type = string
}

variable "kms_key_arn_sqs" {
  type = string
}

variable "bedrock_model_arns" {
  description = "ARNs of Bedrock models the agent may invoke."
  type        = list(string)
  default     = []
}

variable "ses_identity_arn" {
  type = string
}

variable "ses_from_address" {
  type = string
}

variable "llm_provider" {
  type    = string
  default = "bedrock"
}

variable "llm_model" {
  type    = string
  default = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "otel_otlp_endpoint" {
  type    = string
  default = ""
}

variable "deletion_protection" {
  description = "ALB deletion protection."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "ECS exec for break-glass debugging. Audited via CloudTrail."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
