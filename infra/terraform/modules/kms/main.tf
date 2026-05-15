###############################################################################
# KMS module
#
# One customer-managed key per use case so policies can be scoped tightly.
# Aliases are predictable: alias/<name_prefix>-<purpose>
#
# Rotation: enabled on every key.
# Deletion window: 30 days (max), so accidental destroys can be recovered.
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
  purposes = toset(var.purposes)
  tags = merge(var.tags, {
    Module = "kms"
  })
}

data "aws_iam_policy_document" "key" {
  for_each = local.purposes

  # Root account can manage the key (required so IAM Identity Center / break-
  # glass admins are not locked out).
  statement {
    sid    = "EnableRootManagement"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CloudWatch Logs needs to use the key for the `logs` purpose.
  dynamic "statement" {
    for_each = each.value == "logs" ? [1] : []
    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]
      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      }
    }
  }

  # SNS / Firehose service principals if used for the audit pipeline.
  dynamic "statement" {
    for_each = each.value == "s3_audit" ? [1] : []
    content {
      sid    = "AllowFirehoseDelivery"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["firehose.amazonaws.com"]
      }
      actions = [
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = local.purposes

  description             = "${var.name_prefix} ${each.value}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key[each.key].json

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-${each.value}"
    Purpose = each.value
  })
}

resource "aws_kms_alias" "this" {
  for_each      = local.purposes
  name          = "alias/${var.name_prefix}-${each.value}"
  target_key_id = aws_kms_key.this[each.key].id
}
