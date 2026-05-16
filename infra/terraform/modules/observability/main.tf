###############################################################################
# Observability module
#
# Provisions:
#   - KMS-encrypted CloudWatch log group for the ECS service
#   - Metric filters for custom SLIs (llm.failure, audit.write)
#   - SNS topic for alarm routing
#   - All SLO alarms from docs/SLO.md
#   - CloudWatch dashboard agent-overview-<env>
#   - Kinesis Firehose audit pipeline:
#       log subscription filter on "audit.write" -> Firehose -> S3 audit bucket
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# Custom metric filters (log group is created by the ecs_service module
# and passed in by name)
###############################################################################

resource "aws_cloudwatch_log_metric_filter" "llm_failure" {
  name           = "${var.name_prefix}-llm-failure"
  log_group_name = var.log_group_name
  pattern        = "{ $.msg = \"llm.failure\" }"

  metric_transformation {
    name      = "LLMFailures"
    namespace = "Saaf/Agent"
    value     = "1"
    unit      = "Count"
    dimensions = {
      Env = var.env
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "audit_write" {
  name           = "${var.name_prefix}-audit-write"
  log_group_name = var.log_group_name
  pattern        = "{ $.msg = \"audit.write\" }"

  metric_transformation {
    name      = "AuditWrites"
    namespace = "Saaf/Agent"
    value     = "1"
    unit      = "Count"
    dimensions = {
      Env = var.env
    }
  }
}

###############################################################################
# Alarm routing topic
###############################################################################

resource "aws_sns_topic" "alarms" {
  name              = "${var.name_prefix}-alarms"
  kms_master_key_id = var.kms_key_arn_sns == "" ? "alias/aws/sns" : var.kms_key_arn_sns
  tags              = var.tags
}

# Subscribe PagerDuty / Slack out-of-band; the topic ARN is exported.

###############################################################################
# Alarms (one per SLO row in docs/SLO.md)
###############################################################################

resource "aws_cloudwatch_metric_alarm" "fivexx_fast" {
  alarm_name          = "${var.name_prefix}-5xx-burn-fast"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 5
  alarm_description   = "5xx > 5% sustained — fast burn"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    return_data = true
    expression  = "100 * m1 / m2"
    label       = "5xxPct"
  }

  metric_query {
    id = "m1"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      period      = 60
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }

  metric_query {
    id = "m2"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      stat        = "Sum"
      period      = 60
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 10
  datapoints_to_alarm = 6
  threshold           = 5
  alarm_description   = "p95 TargetResponseTime > 5s"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  extended_statistic  = "p95"
  period              = 60
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${var.name_prefix}-latency-p99"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 10
  datapoints_to_alarm = 6
  threshold           = 10
  alarm_description   = "p99 TargetResponseTime > 10s"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  extended_statistic  = "p99"
  period              = 60
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "${var.name_prefix}-healthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 2
  alarm_description   = "Healthy hosts below redundancy floor"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  statistic           = "Minimum"
  period              = 60
  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  alarm_name          = "${var.name_prefix}-queue-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 200
  alarm_description   = "SQS visible messages exceed steady-state cap"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  period              = 300
  dimensions          = { QueueName = var.queue_name }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${var.name_prefix}-queue-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 300
  alarm_description   = "Oldest message age > 5 min — consumers lagging"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  period              = 60
  dimensions          = { QueueName = var.queue_name }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_nonzero" {
  alarm_name          = "${var.name_prefix}-dlq-nonzero"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  alarm_description   = "DLQ received a message — investigate immediately"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  statistic           = "Maximum"
  period              = 60
  dimensions          = { QueueName = var.dlq_name }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "llm_failures" {
  alarm_name          = "${var.name_prefix}-llm-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 10
  alarm_description   = "More than 10 LLM failures in 5 min"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "LLMFailures"
  namespace           = "Saaf/Agent"
  statistic           = "Sum"
  period              = 300
  dimensions          = { Env = var.env }
  tags                = var.tags
}

###############################################################################
# Audit pipeline:  CW Logs subscription -> Firehose -> S3 audit bucket
###############################################################################

resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "firehose.amazonaws.com" },
      Action    = "sts:AssumeRole",
      Condition = {
        StringEquals = { "sts:ExternalId" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
  tags = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid    = "S3Write"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      var.audit_bucket_arn,
      "${var.audit_bucket_arn}/*",
    ]
  }
  statement {
    sid       = "KmsForAuditBucket"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn_audit]
  }
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/kinesisfirehose/*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-audit"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn_logs
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = "${var.name_prefix}-audit"
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.kms_key_arn_audit
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = var.audit_bucket_arn
    prefix              = "year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/!{firehose:error-output-type}/"
    buffering_size      = 5
    buffering_interval  = 60
    compression_format  = "GZIP"

    kms_key_arn = var.kms_key_arn_audit

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  tags = var.tags
}

# Subscription filter: every log line whose JSON has msg == "audit.write" goes
# to Firehose. The code emits this via store.write_audit_record.
resource "aws_iam_role" "subscription" {
  name = "${var.name_prefix}-cwlogs-to-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" },
      Action    = "sts:AssumeRole",
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "subscription" {
  role = aws_iam_role.subscription.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"],
      Resource = aws_kinesis_firehose_delivery_stream.audit.arn,
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "audit" {
  name            = "${var.name_prefix}-audit-subscription"
  log_group_name  = var.log_group_name
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn
  role_arn        = aws_iam_role.subscription.arn
  filter_pattern  = "{ $.msg = \"audit.write\" }"
}

resource "aws_cloudwatch_metric_alarm" "audit_freshness" {
  alarm_name          = "${var.name_prefix}-audit-firehose-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 900
  alarm_description   = "Audit Firehose data freshness > 15 min — compliance impact"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "DeliveryToS3.DataFreshness"
  namespace           = "AWS/Firehose"
  statistic           = "Maximum"
  period              = 300
  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.audit.name
  }
  tags = var.tags
}

# Monthly cost guard. AWS publishes EstimatedCharges only in us-east-1
# regardless of the workload's region. The alarm therefore only fires when
# this stack is deployed in us-east-1.
resource "aws_cloudwatch_metric_alarm" "monthly_billing" {
  count               = var.monthly_budget_usd > 0 && data.aws_region.current.region == "us-east-1" ? 1 : 0
  alarm_name          = "${var.name_prefix}-monthly-billing"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.monthly_budget_usd
  alarm_description   = "Monthly EstimatedCharges exceeded $${var.monthly_budget_usd} — investigate runaway LLM spend or other cost drift"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  statistic           = "Maximum"
  period              = 21600 # 6 hours; billing metric updates several times per day
  dimensions = {
    Currency = "USD"
  }
  tags = var.tags
}

###############################################################################
# Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "agent-overview-${var.env}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric",
        x    = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Requests / 5xx %",
          region = data.aws_region.current.region,
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", yAxis = "right" }],
          ],
          period = 60,
          view   = "timeSeries",
        }
      },
      {
        type = "metric",
        x    = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Latency p50/p95/p99",
          region = data.aws_region.current.region,
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ],
          period = 60,
          view   = "timeSeries",
          annotations = {
            horizontal = [
              { value = 5, label = "p95 SLO" },
              { value = 10, label = "p99 SLO" },
            ]
          }
        }
      },
      {
        type = "metric",
        x    = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "SQS depth + age",
          region = data.aws_region.current.region,
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name, { stat = "Maximum" }],
            [".", "ApproximateAgeOfOldestMessage", ".", ".", { stat = "Maximum", yAxis = "right" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", var.dlq_name, { stat = "Maximum", label = "DLQ" }],
          ],
          period = 60,
          view   = "timeSeries",
        }
      },
      {
        type = "metric",
        x    = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "LLM failures / audit writes",
          region = data.aws_region.current.region,
          metrics = [
            ["Saaf/Agent", "LLMFailures", "Env", var.env, { stat = "Sum" }],
            [".", "AuditWrites", ".", ".", { stat = "Sum" }],
          ],
          period = 60,
          view   = "timeSeries",
        }
      },
    ]
  })
}
