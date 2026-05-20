output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "service_arn" {
  value = aws_ecs_service.this.id
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "task_role_name" {
  value = aws_iam_role.task.name
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  description = "Used as CloudWatch dimension."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.this.arn_suffix
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.service.name
}

output "log_group_arn" {
  value = aws_cloudwatch_log_group.service.arn
}
