# Terraform — Underwriting-Assist Agent

Provisions the production AWS infrastructure for the FastAPI service in
`src/agent/`. See `docs/DESIGN.md` for the architecture rationale.

## Layout

```
infra/terraform/
├── envs/
│   └── prod/                    # one composition per environment
│       ├── backend.tf           # remote S3 + DynamoDB state
│       ├── main.tf              # wires modules together
│       ├── outputs.tf
│       ├── variables.tf
│       ├── versions.tf
│       └── terraform.tfvars.example
└── modules/
    ├── network/                 # VPC, subnets, SGs, VPC endpoints
    ├── kms/                     # one CMK per use case
    ├── ecr/                     # ECR repo (immutable tags, scan, lifecycle)
    ├── storage/                 # S3 bucket (used for docs + audit)
    ├── secrets/                 # Secrets Manager + optional rotation
    ├── database/                # RDS PostgreSQL Multi-AZ
    ├── queue/                   # SQS FIFO + DLQ
    ├── ecs_service/             # ECS Fargate + ALB + autoscaling + IAM
    └── observability/           # log filters, alarms, dashboard, audit Firehose
```

## Prerequisites (one-time bootstrap)

The remote-state bucket and lock table must exist before the first
`terraform init`. Create them out-of-band in each AWS account:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${ACCOUNT_ID}-tfstate-prod"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"alias/tfstate"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name tfstate-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then update the `bucket` argument in `envs/prod/backend.tf`.

## OIDC for GitHub Actions

The CI/CD pipelines authenticate to AWS via OIDC, no long-lived keys.
Create an IAM role per account (dev/staging/prod) with:

- Trust policy: GitHub OIDC provider, `sub` condition pinning to
  `repo:<org>/<repo>:ref:refs/heads/main` for deploy roles, broader for CI.
- Permissions:
  - CI role: read-only against the AWS account (so `terraform plan` works
    if used in PRs); no write.
  - Deploy role: scoped to the resources this stack creates plus ECR push,
    ECS update, SSM put. Use a managed policy or fine-grained one — never
    `AdministratorAccess` for the deploy role.

Set the role ARNs in GitHub Actions repo secrets:

| Secret | Used by |
|---|---|
| `AWS_CI_ROLE_ARN` | `.github/workflows/build.yml` (push image) |
| `AWS_DEPLOY_ROLE_ARN` | `.github/workflows/deploy.yml` |

## First-time apply

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars   # fill in account-specific values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The first apply will create the ECR repo with an empty image set; the
ECS task definition will fail to pull until the build pipeline has pushed
its first image. This is expected — push an image, then re-run
`terraform apply` (or trigger the deploy pipeline) to roll out the task
definition with the new digest.

## Verifying compliance posture

After apply, run:

```bash
# Bucket has Object Lock COMPLIANCE 7y
aws s3api get-object-lock-configuration --bucket $(terraform output -raw audit_bucket_name)

# RDS forces SSL
aws rds describe-db-parameters --db-parameter-group-name agent-prod-pg16 \
  --query "Parameters[?ParameterName=='rds.force_ssl']"

# Secrets are KMS-encrypted with a CMK (not aws/secretsmanager)
aws secretsmanager describe-secret --secret-id $(terraform output -raw db_secret_arn) \
  --query 'KmsKeyId'

# Task role can read only the two secrets
aws iam get-role-policy --role-name $(terraform output -raw task_role_arn | awk -F/ '{print $NF}') --policy-name <generated>
```

## Differences across environments

Modules are identical; differences live in tfvars. To bring up a non-prod
environment, copy `envs/prod/` to `envs/dev/`, then in `terraform.tfvars`:

| Override | dev | staging |
|---|---|---|
| `nat_gateway_count` | 1 | 2 |
| `task_cpu` / `task_memory` | 256 / 512 | 512 / 1024 |
| `min_count` | 1 | 2 |
| `max_count` | 4 | 10 |
| `multi_az` (RDS) | false | true |
| `instance_class` (RDS) | db.t4g.micro | db.t4g.small |
| `backup_retention_period` | 7 | 14 |
| `deletion_protection` | false | true |
| `log_retention_days` | 14 | 30 |

Plus the `database` module variables exposed via wrapper tfvars in each env.
