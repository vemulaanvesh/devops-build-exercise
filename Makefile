# Convenience targets for local dev and infra operations.
# CI/CD does not depend on this Makefile.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:

ENV ?= prod
TF_DIR := infra/terraform/envs/$(ENV)

# ---------------- App ----------------

.PHONY: install
install:
	pip install -e ".[dev]"

.PHONY: lint
lint:
	ruff check src tests

.PHONY: test
test:
	pytest -q

.PHONY: run
run:
	uvicorn agent.main:app --host 0.0.0.0 --port 8080 --reload

.PHONY: smoke
smoke:
	curl -fsS -X POST http://localhost:8080/v1/items/process \
	  -H 'Content-Type: application/json' \
	  -d @examples/sample_loan.json | jq

# ---------------- Container ----------------

IMAGE_NAME ?= underwriting-agent
IMAGE_TAG  ?= dev

.PHONY: build
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: scan
scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

# ---------------- Terraform ----------------

.PHONY: tf-fmt
tf-fmt:
	terraform fmt -recursive infra/terraform/

.PHONY: tf-fmt-check
tf-fmt-check:
	terraform fmt -check -recursive infra/terraform/

.PHONY: tf-validate
tf-validate:
	@for dir in infra/terraform/envs/*/; do \
	  echo "==> validating $$dir"; \
	  ( cd "$$dir" && terraform init -backend=false -input=false -upgrade >/dev/null && terraform validate ); \
	done

.PHONY: tf-init
tf-init:
	cd $(TF_DIR) && terraform init -input=false

.PHONY: tf-plan
tf-plan:
	cd $(TF_DIR) && terraform plan -input=false -out=tfplan

.PHONY: tf-apply
tf-apply:
	cd $(TF_DIR) && terraform apply -input=false tfplan

.PHONY: tf-destroy
tf-destroy:
	@if [ "$(ENV)" = "prod" ]; then \
	  echo "Refusing to destroy prod via Makefile. Use AWS console + manual TF."; exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy -input=false

# ---------------- Help ----------------

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
