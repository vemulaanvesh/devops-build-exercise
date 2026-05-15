variable "name_prefix" {
  description = "Name prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK for SSE."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = <<-EOT
    Must exceed worst-case end-to-end processing time so a single in-flight
    item is not delivered twice. Spec p99 < 10s; we set 60s for headroom
    including LLM retries.
  EOT
  type        = number
  default     = 60
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
