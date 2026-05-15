###############################################################################
# Database module — RDS PostgreSQL
#
# Compliance:
#   - KMS encryption at rest (CMK)
#   - rds.force_ssl = 1 (encryption in transit)
#   - Performance Insights with KMS, Enhanced Monitoring
#   - Automated backups + PITR (RPO ≤ 1h satisfied by 5-min PITR granularity)
#   - Multi-AZ (production) for AZ failover inside the 30-min RTO
#   - Deletion protection
#   - CloudWatch log exports for postgresql + upgrade
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-db-subnets" })
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg16"
  family      = "postgres16"
  description = "Underwriting agent PG params"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = var.tags
}

resource "aws_iam_role" "enhanced_monitoring" {
  name = "${var.name_prefix}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "monitoring.rds.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  role       = aws_iam_role.enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = var.name_prefix
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.database_name
  username = var.master_username

  # Password is fetched from Secrets Manager. Managed master password
  # would also work; we use the explicit secret path to keep the rotation
  # Lambda configurable.
  password = var.master_password

  multi_az            = var.multi_az
  publicly_accessible = false

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  port                   = 5432

  parameter_group_name = aws_db_parameter_group.this.name

  backup_retention_period   = var.backup_retention_period
  backup_window             = "07:00-08:00"
  maintenance_window        = "Mon:08:00-Mon:09:00"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-final-${formatdate("YYYYMMDD-hhmm", timestamp())}"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.enhanced_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = false

  lifecycle {
    ignore_changes = [
      password,
      final_snapshot_identifier, # uses timestamp(); always drifts
    ]
  }

  tags = merge(var.tags, { Name = var.name_prefix })
}
