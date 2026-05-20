###############################################################################
# Secrets module
#
# - One Secrets Manager secret per logical credential.
# - KMS-encrypted with the secrets CMK.
# - Optional rotation: if `rotation_lambda_arn` is set, schedules rotation.
#
# Two main consumers in this stack:
#   - db_master_password : rotated by an AWS-provided rotation Lambda
#     (single-user template). Provisioned in the env composition.
#   - anthropic_api_key  : third-party SaaS key; no managed rotation.
#     We emit a CloudWatch alarm 75 days after last rotation as a reminder
#     (handled in the observability module). The secret itself just exists.
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_secretsmanager_secret" "this" {
  name                    = var.secret_name
  description             = var.description
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "initial" {
  count         = var.initial_secret_string == null ? 0 : 1
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = var.initial_secret_string

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_rotation" "this" {
  count               = var.rotation_lambda_arn == null ? 0 : 1
  secret_id           = aws_secretsmanager_secret.this.id
  rotation_lambda_arn = var.rotation_lambda_arn

  rotation_rules {
    automatically_after_days = var.rotation_days
  }
}
