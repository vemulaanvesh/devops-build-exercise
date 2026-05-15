variable "name_prefix" {
  description = "Identifier prefix, e.g. 'agent-prod'."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group (≥2 AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the RDS instance."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN for storage + PI encryption."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.small"
}

variable "allocated_storage" {
  description = "Initial allocated storage (GiB)."
  type        = number
  default     = 50
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 500
}

variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "saaf"
}

variable "master_username" {
  description = "Master DB user."
  type        = string
  default     = "saaf_admin"
}

variable "master_password" {
  description = "Master password (sourced from Secrets Manager in the env)."
  type        = string
  sensitive   = true
}

variable "multi_az" {
  description = "Multi-AZ deployment. Required for 99.9% availability + RTO 30m."
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Days of automated backups. 35 in prod, 7 in dev."
  type        = number
  default     = 35
}

variable "deletion_protection" {
  description = "Deletion protection. Always true in prod."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on destroy. Never true in prod."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
