# Underwriting-Assist Agent — Production Infrastructure

Take-home submission. The agent code in `src/agent/` is unchanged from the
reference skeleton handed over with the spec. Everything outside `src/`,
`tests/`, `examples/`, `Dockerfile`, and `pyproject.toml` is the production
infrastructure built per `# Underwriting-Assist Agent — Service Sp.md`.

## What was built

| Layer | Implementation |
|---|---|
| Compute | AWS ECS Fargate (ARM64 Graviton, Multi-AZ) behind an internal Application Load Balancer |
| Ingestion | Amazon SQS FIFO + Dead Letter Queue with content-based dedup contract |
| State | Amazon RDS PostgreSQL Multi-AZ + two S3 buckets (loan docs, audit with Object Lock COMPLIANCE 7-year retention) |
| Identity | Two-role IAM split (execution + task) with zero `Resource: "*"` grants |
| Secrets | AWS Secrets Manager with 90-day automatic rotation for the DB master credential |
| Encryption | Six customer-managed KMS keys, one per use case (rds, s3_docs, s3_audit, secrets, logs, sqs), rotation enabled |
| Network | VPC with private subnets across 2 AZs, 9 VPC endpoints, no NAT gateway |
| LLM provider | Bedrock primary (via VPC endpoint), Anthropic public API as fallback |
| Observability | CloudWatch Logs + 9 alarms + dashboard + SNS topic + Kinesis Firehose audit pipeline |
| IaC | Terraform 1.6+ with AWS provider v6, modular (9 modules), remote S3 state with DynamoDB lock |
| CI/CD | GitHub Actions: ci.yml (lint+test+IaC scan), build.yml (image build+scan+push), deploy.yml (plan+manual gate+apply), all via OIDC |

## Verification

`terraform plan` was executed against a real AWS sandbox account.

```
$ AWS_PROFILE=<sandbox> terraform plan ...
Plan: 114 to add, 0 to change, 0 to destroy.
```

`terraform apply` was not run because the target accounts (dev/staging/prod)
need three pre-flight resources (ACM certificate, SES verified identity,
Bedrock model access) provisioned per the runbook in
`infra/terraform/README.md`.

## Local verification (no AWS account required)

```bash
make lint              # ruff against the unchanged app code
make test              # pytest -q
make tf-fmt-check      # terraform formatting
make tf-validate       # validate every env composition
```

To do a full plan against your own AWS account:

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars   # fill in REPLACE_ME values
terraform init
terraform plan
```

## Repository layout

```
.
├── src/agent/                    # UNCHANGED — agent code
├── tests/test_smoke.py           # UNCHANGED
├── examples/sample_loan.json     # UNCHANGED
├── Dockerfile                    # UNCHANGED
├── pyproject.toml                # UNCHANGED
├── .env.example                  # UNCHANGED
│
├── infra/terraform/
│   ├── README.md                 # Bootstrap, OIDC roles, first-apply steps
│   ├── modules/                  # 9 reusable modules
│   │   ├── network/                #   VPC, subnets, SGs, VPC endpoints
│   │   ├── kms/                    #   6 customer-managed CMKs
│   │   ├── ecr/                    #   Container registry
│   │   ├── storage/                #   Generic S3 (used for docs + audit)
│   │   ├── secrets/                #   Secrets Manager wrapper
│   │   ├── database/               #   RDS PostgreSQL Multi-AZ
│   │   ├── queue/                  #   SQS FIFO + DLQ
│   │   ├── observability/          #   Log group, alarms, dashboard, audit pipeline
│   │   └── ecs_service/            #   Fargate cluster + ALB + autoscaling + IAM
│   └── envs/prod/                # Composition wiring all modules
│
├── .github/workflows/
│   ├── ci.yml                    # PR + main: lint, test, validate, IaC scan
│   ├── build.yml                 # main: build + image scan + push to ECR
│   └── deploy.yml                # plan → manual approval gate → apply
│
├── Makefile                      # Local convenience targets
└── README.md                     # this file
```

## Running the application locally

The agent runs unchanged from the skeleton:

```bash
cp .env.example .env                # leave ANTHROPIC_API_KEY blank to mock the LLM
pip install -e ".[dev]"
uvicorn agent.main:app --host 0.0.0.0 --port 8080 --reload

curl -X POST http://localhost:8080/v1/items/process \
  -H "Content-Type: application/json" \
  -d @examples/sample_loan.json | jq
```

Health endpoints: `GET /healthz` (liveness) and `GET /readyz` (Postgres + S3
connectivity).
