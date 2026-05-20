variable "repository_name" {
  description = "ECR repository name."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for repository encryption."
  type        = string
}

variable "keep_image_count" {
  description = "Number of tagged images to retain."
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Allow Terraform destroy even if images exist (non-prod only)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
