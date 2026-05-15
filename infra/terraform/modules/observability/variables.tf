variable "name_prefix" {
  description = "Name prefix."
  type        = string
}

variable "env" {
  description = "Environment label used as metric dimension."
  type        = string
}

variable "log_group_name" {
  description = "Name of the service log group (created by ecs_service module)."
  type        = string
}

variable "kms_key_arn_logs" {
  description = "KMS key ARN for Firehose log group encryption."
  type        = string
}

variable "kms_key_arn_audit" {
  description = "KMS key ARN for the audit bucket (used by Firehose)."
  type        = string
}

variable "kms_key_arn_sns" {
  description = "KMS key ARN for SNS topic. Empty string => use aws/sns managed key."
  type        = string
  default     = ""
}

variable "audit_bucket_arn" {
  description = "S3 audit bucket ARN."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CW dimensions."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix for CW dimensions."
  type        = string
}

variable "queue_name" {
  description = "Primary SQS queue name."
  type        = string
}

variable "dlq_name" {
  description = "DLQ name."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
