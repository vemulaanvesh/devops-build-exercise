###############################################################################
# Queue module — SQS FIFO + DLQ
#
# - FIFO with content-based dedup OFF (callers must set MessageDeduplicationId
#   themselves, derived from (loan_id, item_id, attempt_id)). This is more
#   defensive than content-based dedup.
# - KMS-encrypted with the queue CMK.
# - Visibility timeout sized for p99 latency + LLM retries.
# - DLQ with same encryption; redrive policy maxReceiveCount = 3.
# - SSE TLS-required policy.
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_sqs_queue" "dlq" {
  name                              = "${var.name_prefix}-items-dlq.fifo"
  fifo_queue                        = true
  message_retention_seconds         = 1209600 # 14 days
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, { Name = "${var.name_prefix}-items-dlq" })
}

resource "aws_sqs_queue" "items" {
  name                              = "${var.name_prefix}-items.fifo"
  fifo_queue                        = true
  content_based_deduplication       = false
  deduplication_scope               = "messageGroup"
  fifo_throughput_limit             = "perMessageGroupId"
  message_retention_seconds         = 345600 # 4 days
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  receive_wait_time_seconds         = 10 # long polling
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn,
    maxReceiveCount     = 3,
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-items" })
}

# Enforce TLS-in-transit on both queues.
# Use static map keys so for_each is plannable before the queues exist.
locals {
  queues_by_name = {
    items = aws_sqs_queue.items.arn
    dlq   = aws_sqs_queue.dlq.arn
  }
}

data "aws_iam_policy_document" "deny_insecure" {
  for_each = local.queues_by_name

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [each.value]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "items" {
  queue_url = aws_sqs_queue.items.id
  policy    = data.aws_iam_policy_document.deny_insecure["items"].json
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.deny_insecure["dlq"].json
}
