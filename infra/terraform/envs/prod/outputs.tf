output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "Internal ALB DNS — register a private Route53 alias to this."
  value       = module.ecs.alb_dns_name
}

output "alb_zone_id" {
  value = module.ecs.alb_zone_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "task_role_arn" {
  value = module.ecs.task_role_arn
}

output "execution_role_arn" {
  value = module.ecs.execution_role_arn
}

output "target_group_arn" {
  value = module.ecs.target_group_arn
}

output "queue_url" {
  value = module.queue.queue_url
}

output "queue_arn" {
  value = module.queue.queue_arn
}

output "dlq_url" {
  value = module.queue.dlq_url
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "docs_bucket_name" {
  value = module.docs_bucket.bucket_name
}

output "audit_bucket_name" {
  value = module.audit_bucket.bucket_name
}

output "db_secret_arn" {
  value = module.db_secret.secret_arn
}

output "anthropic_secret_arn" {
  value = module.anthropic_secret.secret_arn
}

output "kms_keys" {
  value = module.kms.alias_by_purpose
}

output "log_group_name" {
  value = module.ecs.log_group_name
}

output "dashboard_name" {
  value = module.observability.dashboard_name
}

output "alarms_topic_arn" {
  value = module.observability.sns_alarms_arn
}

output "firehose_audit_stream_arn" {
  value = module.observability.firehose_stream_arn
}
