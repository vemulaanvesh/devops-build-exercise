###############################################################################
# ECS Fargate service + ALB + autoscaling + IAM
#
# Wires together:
#   - ECS cluster (Fargate-only, with Container Insights)
#   - Task definition pulling secrets from Secrets Manager via the
#     execution role; injecting non-secret config via env vars
#   - Service with deployment circuit breaker, rolling deploy, awsvpc
#     networking, attached to ALB target group
#   - ALB (internal by default) with HTTPS listener, modern TLS policy,
#     HTTP -> HTTPS redirect, access logs to S3 (optional)
#   - Task role with least-privilege policies for: docs bucket prefix,
#     audit bucket prefix (write only), SQS receive/delete, Bedrock invoke,
#     SES send, KMS decrypt scoped per key, Secrets Manager scoped per ARN
#   - Application Auto Scaling: target tracking on CPU + ALB RPS
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { Module = "ecs_service" })
}

###############################################################################
# Cluster
###############################################################################

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }

  tags = local.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = var.min_count
  }
}

###############################################################################
# Log group
#
# Owned by this module so the awslogs driver and the IAM execution role can
# reference it without an external module dependency. The observability
# module consumes the name/ARN read-only to attach metric filters, a
# subscription filter to Firehose, and alarms.
###############################################################################

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn_logs
  tags              = local.tags
}

###############################################################################
# IAM roles
###############################################################################

# Execution role: AWS uses this to pull the image, write logs, and resolve
# secrets/parameters at task launch time.
data "aws_iam_policy_document" "exec_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.exec_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "exec_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_extra" {
  # Decrypt secrets for env injection (scoped to the secret CMK).
  statement {
    sid       = "DecryptSecretsKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn_secrets]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "ReadSpecificSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = var.secret_arns
  }

  statement {
    sid    = "WriteServiceLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.service.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution_extra" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_extra.json
}

# Task role: granted to the running container's process. THIS is the
# IAM principal that appears in audit records.
data "aws_iam_policy_document" "task_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task" {
  # Docs bucket: read + write to the loan_id-prefixed area.
  statement {
    sid    = "DocsBucketObjectRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.docs_bucket_arn,
      "${var.docs_bucket_arn}/*",
    ]
  }

  # Audit bucket: write-only (we never read audit; pipeline writes via Firehose,
  # the app may want to write a structured record directly in future).
  statement {
    sid    = "AuditBucketWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${var.audit_bucket_arn}/app/*",
    ]
  }

  statement {
    sid    = "AuditBucketHead"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
    ]
    resources = [var.audit_bucket_arn]
  }

  # SQS: receive + delete from items queue; no admin.
  statement {
    sid    = "SQSConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.queue_arn]
  }

  # Bedrock invoke — only for the configured model ARN.
  dynamic "statement" {
    for_each = var.bedrock_model_arns
    content {
      sid       = "BedrockInvoke${statement.key}"
      effect    = "Allow"
      actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      resources = [statement.value]
    }
  }

  # SES send — restricted to the verified identity.
  statement {
    sid    = "SESSend"
    effect = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = [var.ses_identity_arn]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.ses_from_address]
    }
  }

  # KMS decrypt for each resource CMK (docs, audit, secrets).
  statement {
    sid       = "KmsDecryptDocs"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn_docs]
  }

  statement {
    sid       = "KmsEncryptAudit"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.kms_key_arn_audit]
  }

  statement {
    sid       = "KmsDecryptQueue"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn_sqs]
  }

  # ECS Exec (Session Manager) — required so `aws ecs execute-command`
  # works as a break-glass debug tool. Channels are session-scoped, no
  # broad access to SSM parameters or anything else.
  statement {
    sid    = "ECSExecSessionManager"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  # CloudWatch metric publish for custom metrics if the app emits them via SDK.
  statement {
    sid       = "CWMetricPublish"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Saaf/Agent"]
    }
  }

  # X-Ray / OTLP (AWS Distro for OpenTelemetry).
  statement {
    sid    = "OTELXRay"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

###############################################################################
# Task definition
###############################################################################

locals {
  container_name = "agent"

  # Environment variables for the agent container. Secrets go in `secrets`
  # below, not here.
  base_env = [
    { name = "PORT", value = tostring(var.container_port) },
    { name = "LOG_LEVEL", value = var.log_level },
    { name = "ENVIRONMENT", value = var.env },
    { name = "S3_BUCKET", value = var.docs_bucket_name },
    { name = "LLM_PROVIDER", value = var.llm_provider },
    { name = "LLM_MODEL", value = var.llm_model },
    { name = "AWS_REGION", value = data.aws_region.current.region },
    { name = "SES_FROM_ADDRESS", value = var.ses_from_address },
    { name = "OTEL_SERVICE_NAME", value = "underwriting-agent" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = var.otel_otlp_endpoint },
  ]
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture # ARM64 by default (Graviton)
  }

  container_definitions = jsonencode([{
    name                   = local.container_name
    image                  = var.image_uri
    essential              = true
    readonlyRootFilesystem = true
    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]
    environment = local.base_env
    secrets = [
      {
        name      = "DATABASE_URL"
        valueFrom = "${var.db_secret_arn}:database_url::"
      },
      {
        name      = "ANTHROPIC_API_KEY"
        valueFrom = "${var.anthropic_secret_arn}:api_key::"
      },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "agent"
        mode                  = "non-blocking"
        max-buffer-size       = "25m"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.container_port}/healthz || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
    # Read-only root needs a writable tmp.
    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]
  }])

  volume {
    name = "tmp"
  }

  tags = local.tags
}

###############################################################################
# ALB
###############################################################################

resource "aws_lb" "this" {
  name               = substr("${var.name_prefix}-alb", 0, 32)
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.alb_internal ? var.private_subnet_ids : var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 30

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  name                 = substr("${var.name_prefix}-tg", 0, 32)
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

###############################################################################
# Service
###############################################################################

resource "aws_ecs_service" "this" {
  name            = var.name_prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  enable_execute_command            = var.enable_execute_command
  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns this after first apply
  }

  depends_on = [aws_lb_listener.https]
  tags       = local.tags
}

###############################################################################
# Autoscaling
###############################################################################

resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name_prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 55
    scale_in_cooldown  = 120
    scale_out_cooldown = 30
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "alb_rps" {
  name               = "${var.name_prefix}-alb-rps"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.requests_per_target_target
    scale_in_cooldown  = 180
    scale_out_cooldown = 30
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.this.arn_suffix}"
    }
  }
}
