# Oracle → PostgreSQL Migration — Makefile
#
# The namespace parameter (NS) isolates every run into its own PostgreSQL
# schema, so multiple demo runs, parallel sessions, and per-team migrations
# never collide. Default: dev.
#
# In the Oracle world objects were deployed via SQL*Plus scripts and promoted
# manually through environments. This Makefile replaces that with repeatable,
# one-command lifecycle management on PostgreSQL (or EnterpriseDB).

NS       ?= dev
SHELL    := /bin/bash
PYTHON   := python3

# PostgreSQL connection uses standard libpq environment variables:
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
PSQL     := psql -v ON_ERROR_STOP=1

.PHONY: help install lint seed teardown-seed build test reconcile \
        demo-up demo-down ci docker-up docker-down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install Python dependencies + pre-commit hooks
	pip install -r requirements.txt -r seed/requirements.txt -r verify/requirements.txt
	pre-commit install

lint: ## Lint SQL files with sqlfluff (PostgreSQL dialect)
	sqlfluff lint migrations/ --dialect postgres --config .sqlfluff

seed: ## Load synthetic data into the raw schema (idempotent)
	$(PYTHON) seed/generate_and_load.py --schema raw

teardown-seed: ## Drop raw schema (caution: removes source data)
	$(PYTHON) seed/teardown.py --schema raw

build: ## Deploy converted objects into namespace NS
	@echo "=== Deploying into namespace: $(NS) ==="
	$(PYTHON) seed/deploy.py --namespace $(NS) --migrations-dir migrations/

test: ## Run reconciliation controls (fails on any FAIL)
	$(PYTHON) verify/reconcile.py --namespace $(NS) --raw-schema raw --mode test

reconcile: ## Source→target reconciliation report
	$(PYTHON) verify/reconcile.py --namespace $(NS) --raw-schema raw \
		--mode report --output reconciliation-report.md

demo-up: seed build reconcile ## Full lifecycle: seed + build + reconcile
	@echo "=== Demo UP complete (namespace: $(NS)) ==="

demo-down: ## Drop namespace schema (raw data untouched)
	$(PYTHON) seed/teardown.py --schema $(NS)
	@echo "=== Demo DOWN complete (namespace: $(NS)) ==="

ci: lint build test ## CI pipeline: lint + build + test

# --- Docker helpers (local development) ---

docker-up: ## Start PostgreSQL in Docker and create the database
	docker run -d --name postgres-demo \
		-e POSTGRES_PASSWORD=$(PGPASSWORD) \
		-e POSTGRES_DB=$(PGDATABASE) \
		-p $(PGPORT):5432 \
		postgres:16
	@echo "Waiting for PostgreSQL to start..."
	@sleep 8

docker-down: ## Stop and remove the PostgreSQL container
	docker stop postgres-demo && docker rm postgres-demo
