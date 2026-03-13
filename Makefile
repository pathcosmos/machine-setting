.PHONY: setup update push status export venv detect help doctor recover verify uninstall uninstall-dry dry-run reset plan preflight gpu-extras

SHELL := /bin/bash
REPO_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

plan: ## Pre-flight check (show what would be installed/updated)
	$(REPO_DIR)/scripts/preflight.sh --check-only

preflight: ## Pre-flight check then selective install
	$(REPO_DIR)/setup.sh --preflight

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

doctor: ## Run health check
	$(REPO_DIR)/scripts/doctor.sh

recover: ## Auto-recover broken components
	$(REPO_DIR)/scripts/doctor.sh --recover

verify: ## Verify installed packages vs requirements
	$(REPO_DIR)/scripts/doctor.sh --verify-packages

uninstall: ## Interactive uninstall
	$(REPO_DIR)/scripts/uninstall.sh

dry-run: ## Full system dry-run diagnostic (all 7 stages)
	$(REPO_DIR)/scripts/dry-run.sh

uninstall-dry: ## Show what would be removed
	$(REPO_DIR)/scripts/uninstall.sh --dry-run

reset: ## Reset install state and start fresh
	$(REPO_DIR)/setup.sh --reset

gpu-extras: ## Install GPU extras only (system tools + kernel tuning; sudo). Use when driver/CUDA already installed.
	$(REPO_DIR)/scripts/install-nvidia.sh --extras-only
