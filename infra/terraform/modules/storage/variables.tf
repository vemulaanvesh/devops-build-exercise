variable "bucket_name" {
  description = "Globally unique S3 bucket name."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for SSE-KMS."
  type        = string
}

variable "object_lock_enabled" {
  description = "Enable Object Lock (immutable storage)."
  type        = bool
  default     = false
}

variable "object_lock_mode" {
  description = "Object Lock mode: GOVERNANCE or COMPLIANCE."
  type        = string
  default     = "COMPLIANCE"
  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "object_lock_retention_days" {
  description = "Object Lock default retention in days."
  type        = number
  default     = 2557 # 7 years + 2 leap days
}

variable "lifecycle_rules" {
  description = <<-EOT
    List of lifecycle rules. Each rule is an object:
      {
        id              = string
        prefix          = string (optional)
        transitions     = list({ days = number, storage_class = string })
        expiration_days = number (optional)
        noncurrent_transitions = list({ days = number, storage_class = string })
      }
  EOT
  type        = list(any)
  default     = []
}

variable "bucket_policy_json" {
  description = "Optional bucket policy JSON."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow Terraform destroy with objects present. Never true in prod."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
