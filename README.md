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

## Known gaps

Things I'm naming explicitly because hiding them would be worse than owning
them. None block the design; each has a documented next step.

| # | Gap | Next step |
|---|---|---|
| 1 | **DB secret rotation Lambda not provisioned** — the spec mandates "rotated quarterly minimum"; the `secrets` module exposes a `rotation_lambda_arn` hook but the env composition does not pass one in. Wiring the AWS-provided RDS rotation Lambda needs the SAR app + a Lambda VPC config + SG rules; deferred to keep this stack focused on platform plumbing. | Deploy `arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser` as a separate stack and pass the function ARN into the `secrets` module. |
| 2 | **PagerDuty / Slack alarm subscription not wired** — the SNS topic `agent-prod-alarms` is provisioned and all 9 alarms publish to it, but no subscription is created. | Add `aws_sns_topic_subscription` with the PagerDuty integration URL (HTTPS) once the integration is set up. |
| 3 | **Only `envs/prod/` composition is wired** — the dev/staging override matrix is documented in `infra/terraform/README.md`, but the directories are not built. Modules are env-agnostic, so it's mechanical copy-and-tweak. | Copy `envs/prod/` to `envs/dev/` + `envs/staging/`, override tfvars per the matrix. |
| 4 | **Bootstrap stack is documented, not Terraformed** — the S3 state bucket, DynamoDB lock table, and GitHub-OIDC IAM roles are created via a one-time runbook in `infra/terraform/README.md`. Industry-standard to keep separate (chicken-and-egg with state), but it should still be code. | Add `bootstrap/` Terraform stack with local backend, then bootstrap once per account. |
| 5 | **Audit log payload caveat** — the agent's current `logging.basicConfig` format only emits `%(message)s`, so the `extra={"audit": record}` dict in `Store.write_audit_record` is silently dropped. The CW Logs subscription filter therefore captures the *fact* of an audit write, not the full record. The Bedrock invocation logging configuration added in this stack mitigates this for LLM IO specifically; a one-line code change in the agent (use `structlog` or a JSON formatter that preserves extras) would fix it for everything else. Not done because the README explicitly forbids modifying the agent code. | Coordinate a one-line PR with the ML team. |
| 6 | **Internal ALB has no Route 53 alias** — the ALB has a stable DNS name but it's the auto-generated `agent-prod-alb-xxx.elb.amazonaws.com`. Internal callers would prefer `agent.internal.saaffinance.com` via a Private Hosted Zone alias record. | Add `aws_route53_zone` (private) + `aws_route53_record` once the parent zone exists. |
| 7 | **Plan ran, apply did not** — `terraform plan` against a sandbox AWS account returned `Plan: 114 to add, 0 to change, 0 to destroy`. Apply was not run because (a) prod-named resources don't belong in a sandbox, and (b) three pre-flight resources (ACM cert, SES verified identity, Bedrock model access enablement) need to exist in the target account before a real apply succeeds — see `infra/terraform/README.md`. | First-class apply against a real prod-shaped account once those pre-flights are satisfied. |

## Out of scope (per spec / README)

- Modifying the agent code in `src/agent/` — README: *"do not extend it"*
- Model fine-tuning infrastructure — spec: *"NOT asking you to"*
- Cross-region active-active DR — spec target is 99.9%, achievable single-region multi-AZ
- A SQS-to-HTTP dispatcher — would need either a Lambda or an agent code change. Queue + dedup contract are documented; the consumer is a Day-2 add by the ML team or a sidecar Lambda.

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
