variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "purposes" {
  description = <<-EOT
    Logical purposes to create CMKs for. Each becomes a separate key with
    a scoped policy. Recognized special names: "logs", "s3_audit"
    (adds service-principal grants automatically).
  EOT
  type        = list(string)
  default = [
    "rds",
    "s3_docs",
    "s3_audit",
    "secrets",
    "logs",
    "sqs",
  ]
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
