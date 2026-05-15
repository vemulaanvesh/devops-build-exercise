output "key_arn_by_purpose" {
  description = "Map of purpose -> KMS key ARN."
  value       = { for p, k in aws_kms_key.this : p => k.arn }
}

output "key_id_by_purpose" {
  description = "Map of purpose -> KMS key ID."
  value       = { for p, k in aws_kms_key.this : p => k.key_id }
}

output "alias_by_purpose" {
  description = "Map of purpose -> KMS alias name."
  value       = { for p, a in aws_kms_alias.this : p => a.name }
}
