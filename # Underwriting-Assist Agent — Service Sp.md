# Underwriting-Assist Agent — Service Specification

## Service summary
A FastAPI service hosting an LLM-powered agent that processes outstanding
underwriting items on approved-pending loans. For each item, the agent
classifies the item type, decides on the next action (request document
from borrower, email appraiser, schedule renewal, escalate to human),
and emits a structured task record + optional draft email.

## Runtime characteristics
- **Language / runtime:** Python 3.11, FastAPI, uvicorn
- **Image size:** ~600 MB (model SDKs included)
- **Cold-start tolerance:** moderate (~5s acceptable)
- **Stateless:** yes, all state in Postgres / S3
- **Outbound dependencies:** Anthropic API (or AWS Bedrock), internal
  Postgres (loan + borrower), S3 (uploaded docs), SES (outbound email)

## Throughput & SLOs
| Metric | Today | 12-month target |
| --- | --- | --- |
| Loans / month | 500 | 5,000 |
| Items / loan | 3–5 | 3–5 |
| Daily peak (items / hour) | ~25 | ~250 |
| p95 end-to-end latency | < 8s | < 5s |
| p99 end-to-end latency | < 15s | < 10s |
| Availability | 99.5% | 99.9% |

## Concurrency
- Each item is independent; horizontal scale-out is fine
- LLM calls dominate latency; per-item compute is light
- Bursty arrival pattern — items land in batches when loan officers
  finish underwriter reviews (typically 9am–11am ET, 2pm–4pm ET)

## Data classes & PII
- Loan files contain borrower PII (name, email, phone, entity)
- Loan files contain financial data (income, deposits, balances)
- Underwriter notes may contain legal-sensitive language
- All inbound documents (bank statements, appraisals, insurance
  policies) are stored in S3 and referenced by the agent
- LLM provider must be configured with no-training data agreement

## Compliance requirements (financial services)
- Encryption at rest (KMS-managed) for all data stores
- Encryption in transit (TLS 1.2+) for all service-to-service calls
- Auditable trail of every LLM call: input, output, model, timestamp,
  loan ID, item ID, IAM principal — retained 7 years
- Least-privilege IAM for service identity
- Secrets (LLM API keys, DB creds) rotated quarterly minimum
- No production data in non-prod environments

## Reliability targets
- RPO: 1 hour for loan/item state
- RTO: 30 minutes for agent service
- Loan/item processing must be idempotent — retries must not
  duplicate outbound emails or duplicate task records

## Cost guidance
- Today's labor cost: ~20 min loan-officer time per item ≈ $14 / item
- Target end-state: agent cost (compute + LLM) ≤ $1.50 / item at p50

## Out of scope for the agent itself
- The agent code is being shipped by a separate ML team — you do not
  need to modify it. Your job is to deploy and operate it.
- We are NOT asking you to design model fine-tuning infra in this exercise.
  You may discuss it in the writeup if relevant.