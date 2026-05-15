###############################################################################
# Prod composition for the underwriting-assist agent.
#
# Stitches every module from infra/terraform/modules into a single stack.
# Order:
#   1. KMS keys (no deps)
#   2. Network (no deps)
#   3. ECR repo + S3 buckets (need KMS)
#   4. Secrets (need KMS)
#   5. RDS (needs network, KMS, secret value)
#   6. SQS (needs KMS)
#   7. Observability (needs ALB ARN suffix → done after ECS service, so we
#      build a minimal alarm/dashboard skeleton AND the audit pipeline that
#      doesn't depend on ALB)
#   8. ECS service + ALB (needs all of the above)
#   9. Observability ALB-bound alarms patched in via module composition.
###############################################################################

locals {
  common_tags = {
    Project = "underwriting-agent"
    Env     = "prod"
    Owner   = "devops"
  }
}

###############################################################################
# 1. KMS
###############################################################################

module "kms" {
  source      = "../../modules/kms"
  name_prefix = var.name_prefix
  purposes    = ["rds", "s3_docs", "s3_audit", "secrets", "logs", "sqs"]
  tags        = local.common_tags
}

###############################################################################
# 2. Network
###############################################################################

module "network" {
  source             = "../../modules/network"
  name_prefix        = var.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  nat_gateway_count  = var.nat_gateway_count
  alb_ingress_cidrs  = var.alb_ingress_cidrs
  ecs_container_port = 8080
  tags               = local.common_tags
}

###############################################################################
# 3. ECR + S3 buckets
###############################################################################

module "ecr" {
  source           = "../../modules/ecr"
  repository_name  = "${var.name_prefix}-agent"
  kms_key_arn      = module.kms.key_arn_by_purpose["s3_docs"] # use docs key for ECR too; create dedicated 'ecr' key if you prefer
  keep_image_count = 30
  force_delete     = false
  tags             = local.common_tags
}

module "docs_bucket" {
  source              = "../../modules/storage"
  bucket_name         = var.docs_bucket_name
  kms_key_arn         = module.kms.key_arn_by_purpose["s3_docs"]
  object_lock_enabled = false
  tags                = local.common_tags

  lifecycle_rules = [
    {
      id     = "docs-tiering"
      prefix = ""
      transitions = [
        { days = 30, storage_class = "STANDARD_IA" },
        { days = 90, storage_class = "GLACIER_IR" },
      ]
      noncurrent_transitions = [
        { days = 30, storage_class = "STANDARD_IA" },
      ]
    }
  ]
}

module "audit_bucket" {
  source                     = "../../modules/storage"
  bucket_name                = var.audit_bucket_name
  kms_key_arn                = module.kms.key_arn_by_purpose["s3_audit"]
  object_lock_enabled        = true
  object_lock_mode           = "COMPLIANCE"
  object_lock_retention_days = 2557 # 7 years
  tags                       = local.common_tags

  lifecycle_rules = [
    {
      id     = "audit-tiering"
      prefix = ""
      transitions = [
        { days = 30, storage_class = "STANDARD_IA" },
        { days = 180, storage_class = "GLACIER" },
        { days = 365, storage_class = "DEEP_ARCHIVE" },
      ]
    }
  ]
}

###############################################################################
# 4. Secrets
###############################################################################

# Random DB password seed. Lifecycle ignores subsequent rotations.
resource "random_password" "db_master" {
  length           = 40
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = all
  }
}

module "db_secret" {
  source        = "../../modules/secrets"
  secret_name   = "${var.name_prefix}/db-master"
  description   = "RDS master password + connection URL"
  kms_key_arn   = module.kms.key_arn_by_purpose["secrets"]
  rotation_days = 90

  initial_secret_string = jsonencode({
    username     = "saaf_admin"
    password     = random_password.db_master.result
    engine       = "postgres"
    host         = "TBD-set-after-rds-created"
    port         = 5432
    dbname       = "saaf"
    database_url = "TBD-set-after-rds-created"
  })

  tags = local.common_tags
}

module "anthropic_secret" {
  source      = "../../modules/secrets"
  secret_name = "${var.name_prefix}/anthropic"
  description = "Anthropic API key (rotate quarterly via PagerDuty reminder)"
  kms_key_arn = module.kms.key_arn_by_purpose["secrets"]

  # No managed rotation for third-party SaaS keys; reminder via CW alarm
  # (out of scope for this module — wire as an EventBridge schedule).
  initial_secret_string = jsonencode({ api_key = "" })

  tags = local.common_tags
}

###############################################################################
# 5. RDS
###############################################################################

module "database" {
  source            = "../../modules/database"
  name_prefix       = var.name_prefix
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.rds_security_group_id
  kms_key_arn       = module.kms.key_arn_by_purpose["rds"]

  engine_version          = "16.4"
  instance_class          = "db.m7g.large"
  allocated_storage       = 100
  max_allocated_storage   = 1000
  multi_az                = true
  backup_retention_period = 35
  deletion_protection     = true
  skip_final_snapshot     = false

  database_name   = "saaf"
  master_username = "saaf_admin"
  master_password = random_password.db_master.result

  tags = local.common_tags
}

# After the DB is created, overwrite the secret value with the real
# connection details. We do this in a separate version so the rotation
# Lambda's expected JSON shape (username/password/host/port/dbname) lines up.
resource "aws_secretsmanager_secret_version" "db_realized" {
  secret_id = module.db_secret.secret_id
  secret_string = jsonencode({
    username     = "saaf_admin"
    password     = random_password.db_master.result
    engine       = "postgres"
    host         = module.database.endpoint
    port         = module.database.port
    dbname       = module.database.database_name
    database_url = replace(module.database.connection_url_template, "__PASSWORD__", random_password.db_master.result)
  })

  # Rotation will replace this; never overwrite manually after first apply.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

###############################################################################
# 6. SQS
###############################################################################

module "queue" {
  source      = "../../modules/queue"
  name_prefix = var.name_prefix
  kms_key_arn = module.kms.key_arn_by_purpose["sqs"]
  tags        = local.common_tags
}

###############################################################################
# 7. ECS service + ALB (creates its own log group; observability consumes it)
###############################################################################

module "ecs" {
  source = "../../modules/ecs_service"

  name_prefix = var.name_prefix
  env         = "prod"

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  ecs_security_group_id = module.network.ecs_security_group_id

  alb_internal        = true
  acm_certificate_arn = var.acm_certificate_arn

  image_uri      = var.image_uri
  container_port = 8080

  task_cpu         = var.task_cpu
  task_memory      = var.task_memory
  cpu_architecture = "ARM64"

  desired_count = var.desired_count
  min_count     = var.min_count
  max_count     = var.max_count

  log_level          = "INFO"
  log_retention_days = var.log_retention_days
  kms_key_arn_logs   = module.kms.key_arn_by_purpose["logs"]

  db_secret_arn        = module.db_secret.secret_arn
  anthropic_secret_arn = module.anthropic_secret.secret_arn
  secret_arns = [
    module.db_secret.secret_arn,
    module.anthropic_secret.secret_arn,
  ]

  docs_bucket_name = module.docs_bucket.bucket_name
  docs_bucket_arn  = module.docs_bucket.bucket_arn
  audit_bucket_arn = module.audit_bucket.bucket_arn

  queue_arn = module.queue.queue_arn

  kms_key_arn_secrets = module.kms.key_arn_by_purpose["secrets"]
  kms_key_arn_docs    = module.kms.key_arn_by_purpose["s3_docs"]
  kms_key_arn_audit   = module.kms.key_arn_by_purpose["s3_audit"]
  kms_key_arn_sqs     = module.kms.key_arn_by_purpose["sqs"]

  bedrock_model_arns = var.bedrock_model_arns
  ses_identity_arn   = var.ses_identity_arn
  ses_from_address   = var.ses_from_address

  llm_provider = var.llm_provider
  llm_model    = var.llm_model

  otel_otlp_endpoint = var.otel_otlp_endpoint

  deletion_protection = true

  tags = local.common_tags
}

###############################################################################
# 8. Observability (alarms + audit pipeline; consumes ECS outputs)
###############################################################################

module "observability" {
  source                  = "../../modules/observability"
  name_prefix             = var.name_prefix
  env                     = "prod"
  log_group_name          = module.ecs.log_group_name
  kms_key_arn_logs        = module.kms.key_arn_by_purpose["logs"]
  kms_key_arn_audit       = module.kms.key_arn_by_purpose["s3_audit"]
  audit_bucket_arn        = module.audit_bucket.bucket_arn
  alb_arn_suffix          = module.ecs.alb_arn_suffix
  target_group_arn_suffix = module.ecs.target_group_arn_suffix
  queue_name              = module.queue.queue_name
  dlq_name                = module.queue.dlq_name
  tags                    = local.common_tags
}
