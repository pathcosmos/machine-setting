.PHONY: setup update push status export venv detect help

SHELL := /bin/bash
REPO_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Run full bootstrap setup
	$(REPO_DIR)/setup.sh

update: ## Pull latest changes and update if needed
	$(REPO_DIR)/scripts/sync.sh pull

push: ## Export packages, commit, and push
	$(REPO_DIR)/scripts/sync.sh push

status: ## Show sync status
	$(REPO_DIR)/scripts/sync.sh status

export: ## Export current venv packages to requirements files
	$(REPO_DIR)/scripts/export-packages.sh

check: ## Verify AI environment (GPU, packages)
	$(REPO_DIR)/scripts/check-env.sh

venv: ## Create/update virtual environment
	$(REPO_DIR)/scripts/setup-venv.sh

venv-local: ## Create project-local virtual environment
	$(REPO_DIR)/scripts/setup-venv.sh --local

detect: ## Run hardware detection
	$(REPO_DIR)/scripts/detect-hardware.sh

secrets: ## Scan for potential secrets
	$(REPO_DIR)/scripts/check-secrets.sh $(REPO_DIR)
