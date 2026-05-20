###############################################################################
# Network module
#
# - VPC with /16 CIDR, 2 or 3 AZs
# - Public subnets only for the ALB and optional NAT GW
# - Private subnets for ECS tasks, RDS, and VPC endpoints
# - Interface VPC endpoints for AWS services so compute traffic stays off the
#   public internet (compliance: "Encryption in transit / no public egress")
# - Single NAT Gateway is optional (set nat_gateway_count = 0 to disable
#   public egress entirely and rely on VPC endpoints only)
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

locals {
  azs = slice(data.aws_availability_zones.this.names, 0, var.az_count)

  public_subnet_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  tags = merge(var.tags, {
    Module = "network"
  })
}

data "aws_availability_zones" "this" {
  state = "available"
}

data "aws_region" "current" {}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-igw" })
}

###############################################################################
# VPC Flow Logs
#
# Standard compliance ask for financial-services networks. Captures every
# network flow (5-tuple + bytes + action) to a KMS-encrypted CW Log Group.
# Used for forensics, anomalous-egress detection, and audit reconstruction.
###############################################################################

resource "aws_cloudwatch_log_group" "vpc_flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/${var.name_prefix}-flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_flow_logs ? 1 : 0
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "vpc" {
  count                = var.enable_flow_logs ? 1 : 0
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  tags                 = local.tags
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

###############################################################################
# Routing
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet (allows per-AZ NAT routing if multiple NATs)
resource "aws_route_table" "private" {
  count  = length(aws_subnet.private)
  vpc_id = aws_vpc.this.id
  tags = merge(local.tags, {
    Name = "${var.name_prefix}-rt-private-${local.azs[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# Optional NAT Gateway(s)
#
# Default in prod: 0 NAT GWs (VPC endpoints cover all required egress).
# Set var.nat_gateway_count > 0 if you need ad-hoc public egress (e.g. apt
# updates in a debug task). When > 0, NATs are spread across AZs.
###############################################################################

resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name_prefix}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${var.name_prefix}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  count                  = var.nat_gateway_count > 0 ? length(aws_route_table.private) : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # Distribute private RTs across NATs; if fewer NATs than AZs, wrap around.
  nat_gateway_id = aws_nat_gateway.this[count.index % var.nat_gateway_count].id
}

###############################################################################
# Security groups
#
# Three layers:
#   - alb  : ingress 443 from var.alb_ingress_cidrs (private CIDR if internal ALB)
#   - ecs  : ingress on container port from alb only
#   - rds  : ingress on 5432 from ecs only
#   - vpce : ingress 443 from ecs (so tasks can reach endpoints)
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB ingress"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name_prefix}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.alb_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS ingress to ALB"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs.id
  from_port                    = var.ecs_container_port
  to_port                      = var.ecs_container_port
  ip_protocol                  = "tcp"
  description                  = "ALB to ECS tasks on container port"
}

resource "aws_security_group" "ecs" {
  name        = "${var.name_prefix}-ecs"
  description = "ECS task egress"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name_prefix}-ecs-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.ecs_container_port
  to_port                      = var.ecs_container_port
  ip_protocol                  = "tcp"
  description                  = "From ALB to container"
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_vpce" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.vpce.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "To VPC endpoints"
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_rds" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "To RDS PostgreSQL"
}

# NAT-bound default-out: only if NAT exists. Required for SES API (no VPCE)
# and Anthropic public API. Both omit if you stick to Bedrock + SES SMTP VPCE.
resource "aws_vpc_security_group_egress_rule" "ecs_default_out" {
  count             = var.nat_gateway_count > 0 ? 1 : 0
  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Egress to internet via NAT (SES API, Anthropic)"
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "RDS ingress"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name_prefix}-rds-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.ecs.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "From ECS tasks"
}

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce"
  description = "VPC interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name_prefix}-vpce-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_ecs" {
  security_group_id            = aws_security_group.vpce.id
  referenced_security_group_id = aws_security_group.ecs.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "From ECS to interface endpoints"
}

###############################################################################
# VPC endpoints
#
# - Gateway endpoints (free): S3, DynamoDB
# - Interface endpoints (paid, ~$0.01/hr each): everything else we need
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = merge(local.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

locals {
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "kms",
    "sqs",
    "bedrock-runtime",
    "monitoring",
    # Required by ECS Exec (Session Manager) so break-glass `aws ecs
    # execute-command` works in private subnets without NAT egress.
    "ssm",
    "ssmmessages",
    "ec2messages",
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}
