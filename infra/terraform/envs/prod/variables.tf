variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "agent-prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_anthropic_fallback" {
  description = <<-EOT
    Toggle the Anthropic public-API fallback for the LLM provider.

    Default: false (Bedrock-only, zero public egress).

    When true:
      - Provisions 1 NAT Gateway per AZ so ECS tasks can reach the
        Anthropic public API (which has no AWS VPC endpoint).
      - The agent-prod/anthropic Secrets Manager secret is still
        created either way; populate its api_key value before flipping
        LLM_PROVIDER from bedrock to anthropic.

    Activation steps for an actual failover:
      1. terraform apply -var=enable_anthropic_fallback=true
      2. aws secretsmanager put-secret-value --secret-id agent-prod/anthropic \
           --secret-string '{"api_key":"sk-..."}'
      3. aws ssm put-parameter --name /agent/prod/llm_provider --value anthropic ...
      4. aws ecs update-service --force-new-deployment ...
  EOT
  type        = bool
  default     = false
}

variable "nat_gateway_count" {
  description = <<-EOT
    Override the number of NAT Gateways. By default this is derived from
    enable_anthropic_fallback (false=0 NATs, true=2 NATs across AZs).
    Set explicitly only for ad-hoc debug egress without enabling fallback.
  EOT
  type        = number
  default     = null
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the internal ALB."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the ALB. Must be in the same region."
  type        = string
}

variable "image_uri" {
  description = "Container image URI from ECR, pinned by digest or git SHA."
  type        = string
}

variable "docs_bucket_name" {
  type    = string
  default = "saaf-agent-prod-docs"
}

variable "audit_bucket_name" {
  type    = string
  default = "saaf-agent-prod-audit"
}

variable "llm_provider" {
  description = "anthropic | bedrock | mock"
  type        = string
  default     = "bedrock"
}

variable "llm_model" {
  type    = string
  default = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "bedrock_model_arns" {
  description = "ARNs of Bedrock model IDs the task may invoke."
  type        = list(string)
  default     = []
}

variable "ses_from_address" {
  type    = string
  default = "loans@saaffinance.com"
}

variable "ses_identity_arn" {
  description = "ARN of the SES verified domain or email identity."
  type        = string
}

variable "otel_otlp_endpoint" {
  description = "OTLP endpoint for traces. Empty disables export."
  type        = string
  default     = ""
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 20
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  type    = number
  default = 90
}
