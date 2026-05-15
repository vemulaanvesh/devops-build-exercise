###############################################################################
# ECR module
#
# - Image scan on push (Inspector v2 in the account is preferred, but the
#   repo-level basic scan is enabled as a defense-in-depth fallback).
# - Immutable tags so a deployed git SHA cannot be silently re-pointed.
# - Lifecycle policy keeps the last N production images and untagged images
#   for 14 days.
# - KMS encryption.
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last ${var.keep_image_count} tagged images",
        selection = {
          tagStatus      = "tagged",
          tagPatternList = ["*"],
          countType      = "imageCountMoreThan",
          countNumber    = var.keep_image_count
        },
        action = { type = "expire" }
      },
      {
        rulePriority = 2,
        description  = "Expire untagged images after 14 days",
        selection = {
          tagStatus   = "untagged",
          countType   = "sinceImagePushed",
          countUnit   = "days",
          countNumber = 14
        },
        action = { type = "expire" }
      }
    ]
  })
}
