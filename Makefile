# Makefile for Terraform Infrastructure as Code
# Run terraform commands with environment variables from .env file

# Variables
SHELL := /bin/bash
ENV_FILE := config/.env
ARTIFACTS_DIR := artifacts/terraform
PLAN_FILE := $(ARTIFACTS_DIR)/tfplan
TF_DIR := src

# Default target
.DEFAULT_GOAL := help

# Phony targets (not files)
.PHONY: help init plan apply plan-apply apply-direct apply-force destroy destroy-fast clean validate fmt show list

# Help target - displays available commands
help:
	@echo "Available targets:"
	@echo ""
	@echo "Main Commands:"
	@echo "  make init         - Initialize Terraform providers and modules"
	@echo "  make plan         - Create Terraform execution plan (saved to artifacts)"
	@echo "  make apply        - Apply Terraform changes using saved plan"
	@echo "  make plan-apply   - Create plan and apply immediately (prevents stale plan)"
	@echo ""
	@echo "Alternative Apply Commands:"
	@echo "  make apply-direct - Apply changes directly without plan (auto-approve)"
	@echo "  make apply-force  - Force recreate plan and apply (alias for plan-apply)"
	@echo ""
	@echo "Destroy Commands:"
	@echo "  make destroy      - Destroy all Terraform-managed infrastructure"
	@echo "  make destroy-fast - Fast destroy without refresh (when resources already gone)"
	@echo ""
	@echo "Utility Commands:"
	@echo "  make validate     - Validate Terraform configuration"
	@echo "  make fmt          - Format Terraform files"
	@echo "  make show         - Display current Terraform state"
	@echo "  make list         - List all Terraform resources"
	@echo "  make clean        - Remove artifacts and temporary files"

# Initialize Terraform
init:
	@echo "Initializing Terraform..."
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform init -upgrade

# Validate Terraform configuration
validate:
	@echo "Validating Terraform configuration..."
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform validate

# Format Terraform files
fmt:
	@echo "Formatting Terraform files..."
	@cd $(TF_DIR) && terraform fmt -recursive

# Create Terraform plan and save to artifacts
plan: init
	@echo "Creating Terraform plan..."
	@mkdir -p $(ARTIFACTS_DIR)
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform plan -out=../$(PLAN_FILE)
	@echo "Plan saved to $(PLAN_FILE)"

# Apply Terraform changes using saved plan
apply:
	@if [ ! -f "$(PLAN_FILE)" ]; then \
		echo "Error: Plan file not found. Run 'make plan' first."; \
		exit 1; \
	fi
	@echo "Applying Terraform changes from saved plan..."
	@echo "Note: If you get 'stale plan' error, run 'make plan-apply' instead."
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform apply ../$(PLAN_FILE)

# Plan and apply in one step (prevents stale plan issues)
plan-apply: init
	@echo "Creating and applying Terraform plan..."
	@mkdir -p $(ARTIFACTS_DIR)
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform plan -out=../$(PLAN_FILE)
	@echo "Plan created. Applying changes..."
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform apply ../$(PLAN_FILE)

# Apply without plan (direct apply with auto-approve)
apply-direct: init
	@echo "WARNING: Applying changes directly without saved plan..."
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform apply -auto-approve

# Force apply - recreate plan and apply immediately
apply-force: plan-apply
	@echo "Force apply completed."

# Destroy infrastructure
destroy:
	@echo "WARNING: This will destroy all Terraform-managed infrastructure!"
	@echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
	@sleep 5
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform destroy -auto-approve

# Fast destroy without refresh (use when resources are already gone)
destroy-fast:
	@echo "WARNING: Fast destroy without refresh - use when resources are already deleted!"
	@echo "Press Ctrl+C to cancel, or wait 3 seconds to continue..."
	@sleep 3
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform destroy -auto-approve -refresh=false

# Clean up artifacts
clean:
	@echo "Cleaning up artifacts..."
	@rm -rf artifacts/
	@echo "Artifacts removed."

# Show current Terraform state
show:
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform show

# List Terraform resources
list:
	@cd $(TF_DIR) && set -a && source ../$(ENV_FILE) && set +a && terraform state list
