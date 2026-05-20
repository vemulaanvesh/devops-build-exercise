output "queue_url" {
  value = aws_sqs_queue.items.url
}

output "queue_arn" {
  value = aws_sqs_queue.items.arn
}

output "queue_name" {
  value = aws_sqs_queue.items.name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}
