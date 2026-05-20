output "sns_alarms_arn" {
  value = aws_sns_topic.alarms.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}

output "firehose_stream_arn" {
  value = aws_kinesis_firehose_delivery_stream.audit.arn
}
