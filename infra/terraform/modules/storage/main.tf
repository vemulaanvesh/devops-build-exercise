###############################################################################
# Storage module — one S3 bucket per call
#
# Used twice from the env composition:
#   1. loan_docs  — borrower documents, versioned, KMS, no Object Lock
#   2. audit      — LLM call audit trail, KMS, Object Lock COMPLIANCE 7y
#
# Both buckets:
#   - Block all public access (account-level + bucket-level)
#   - SSE-KMS with bucket-key enabled (cheaper KMS bill)
#   - Versioning on
#   - Lifecycle: transitions to IA after 30d, Glacier IR after 90d, deletion
#     after `expire_days` (default disabled when Object Lock is on)
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  # Object Lock can only be enabled at bucket creation time.
  object_lock_enabled = var.object_lock_enabled

  tags = merge(var.tags, {
    Module = "storage"
    Bucket = var.bucket_name
  })

  # Non-prod escape hatch.
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  count  = var.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.object_lock_mode # "GOVERNANCE" or "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = length(var.lifecycle_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = lookup(rule.value, "prefix", "")
      }

      dynamic "transition" {
        for_each = lookup(rule.value, "transitions", [])
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      dynamic "expiration" {
        for_each = lookup(rule.value, "expiration_days", null) == null ? [] : [1]
        content {
          days = rule.value.expiration_days
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = lookup(rule.value, "noncurrent_transitions", [])
        content {
          noncurrent_days = noncurrent_version_transition.value.days
          storage_class   = noncurrent_version_transition.value.storage_class
        }
      }

      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }
}

# Optional bucket policy — most commonly used to grant Firehose write
# access to the audit bucket.
resource "aws_s3_bucket_policy" "this" {
  count  = var.bucket_policy_json == null ? 0 : 1
  bucket = aws_s3_bucket.this.id
  policy = var.bucket_policy_json
}
