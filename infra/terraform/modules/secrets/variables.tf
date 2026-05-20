variable "secret_name" {
  description = "Name of the secret, e.g. agent/prod/db-master."
  type        = string
}

variable "description" {
  description = "Human-readable description."
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "KMS CMK ARN."
  type        = string
}

variable "initial_secret_string" {
  description = <<-EOT
    Optional initial value to seed the secret with. Treat as bootstrap only;
    the lifecycle rule below ignores subsequent drift so production
    rotations don't trigger Terraform diffs.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "rotation_lambda_arn" {
  description = "Optional rotation Lambda ARN to attach."
  type        = string
  default     = null
}

variable "rotation_days" {
  description = "Rotation schedule in days. 90 satisfies 'quarterly minimum'."
  type        = number
  default     = 90
}

variable "recovery_window_in_days" {
  description = "Deletion recovery window. 30 in prod for accidental-delete safety."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
