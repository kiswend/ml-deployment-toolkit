# Makefile for Terraform Infrastructure as Code
# Run terraform commands with environment variables from .env file
#
# Usage:
#   make plan ENV=cc          # Plan for the cc environment (default)
#   make apply ENV=env-prod   # Apply for the env-prod environment
#   export ENV=cc && make plan  # Set ENV for a session

# Variables
SHELL := /bin/bash
ENV ?= cc
ENV_DIR := config/environments/$(ENV)
ENV_FILE := $(ENV_DIR)/.env
ARTIFACTS_DIR := artifacts/$(ENV)/terraform
PLAN_FILE := $(ARTIFACTS_DIR)/tfplan
TF_DIR := src
BACKEND_CONFIG := path=../artifacts/$(ENV)/terraform/terraform.tfstate

# Load .env and map clean variable names to Terraform's TF_VAR_ convention
# DNS credentials are collected into a single map variable (dns_credentials)
# so any combination of DNS provider variables works without Terraform changes.
LOAD_ENV = set -a && source ../$(ENV_FILE) && set +a && \
	export TF_VAR_env_name=$(ENV) \
	       TF_VAR_dns_credentials='{"digitalocean_token":"'$${DIGITALOCEAN_TOKEN:-}'",'`\
	       `'"cloudflare_api_token":"'$${CLOUDFLARE_API_TOKEN:-}'",'`\
	       `'"aws_dns_access_key_id":"'$${AWS_DNS_ACCESS_KEY_ID:-}'",'`\
	       `'"aws_dns_secret_access_key":"'$${AWS_DNS_SECRET_ACCESS_KEY:-}'",'`\
	       `'"aws_dns_region":"'$${AWS_DNS_REGION:-}'",'`\
	       `'"powerdns_api_url":"'$${POWERDNS_API_URL:-}'",'`\
	       `'"powerdns_api_key":"'$${POWERDNS_API_KEY:-}'",'`\
	       `'"dns_provider_credentials":"'$${DIGITALOCEAN_TOKEN:-}$${CLOUDFLARE_API_TOKEN:-}$${AWS_DNS_ACCESS_KEY_ID:-}$${POWERDNS_API_KEY:-}'"}' \
	       TF_VAR_oci_repo_username=$${OCI_REPO_USERNAME:-} \
	       TF_VAR_oci_repo_password=$${OCI_REPO_PASSWORD:-} \
	       TF_VAR_oci_proxy_username=$${OCI_PROXY_USERNAME:-} \
	       TF_VAR_oci_proxy_password=$${OCI_PROXY_PASSWORD:-} \
	       TF_VAR_minio_root_user=$${MINIO_ROOT_USER:-} \
	       TF_VAR_minio_root_password=$${MINIO_ROOT_PASSWORD:-} \
	       TF_VAR_harbor_admin_password=$${HARBOR_ADMIN_PASSWORD:-} \
	       TF_VAR_mysql_root_password=$${MYSQL_ROOT_PASSWORD:-} \
	       TF_VAR_mysql_central_ledger_password=$${MYSQL_CENTRAL_LEDGER_PASSWORD:-} \
	       TF_VAR_mysql_account_lookup_password=$${MYSQL_ACCOUNT_LOOKUP_PASSWORD:-} \
	       TF_VAR_mysql_oracle_msisdn_password=$${MYSQL_ORACLE_MSISDN_PASSWORD:-} \
	       TF_VAR_mongodb_root_password=$${MONGODB_ROOT_PASSWORD:-} \
	       TF_VAR_mongodb_app_password=$${MONGODB_APP_PASSWORD:-} \
	       TF_VAR_keycloak_db_password=$${KEYCLOAK_DB_PASSWORD:-} \
	       TF_VAR_kratos_db_password=$${KRATOS_DB_PASSWORD:-} \
	       TF_VAR_keto_db_password=$${KETO_DB_PASSWORD:-} \
	       TF_VAR_mcm_db_password=$${MCM_DB_PASSWORD:-} \
	       TF_VAR_keycloak_admin_password=$${KEYCLOAK_ADMIN_PASSWORD:-} \
	       TF_VAR_hubop_oidc_secret=$${HUBOP_OIDC_SECRET:-} \
	       TF_VAR_mcm_oidc_client_secret=$${MCM_OIDC_CLIENT_SECRET:-} \
	       TF_VAR_role_assign_svc_secret=$${ROLE_ASSIGN_SVC_SECRET:-}

# Default target
.DEFAULT_GOAL := help

# GitOps artifact settings (override via env or command line)
GITOPS_DIR := gitops
OCI_REPO := $(shell grep -A4 'repo:' $(ENV_DIR)/config.yaml | grep 'url:' | head -1 | sed 's/.*url: *"*oci:\/\///' | sed 's/"*$$//')
GITOPS_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "latest")

# Phony targets (not files)
.PHONY: help init plan apply plan-apply apply-direct apply-force destroy destroy-fast clean validate fmt show list push-gitops tag-gitops list-artifacts

# Help target - displays available commands
help:
	@echo "Available targets:"
	@echo ""
	@echo "  ENV=<name>  Select environment (default: cc)"
	@echo "              Reads config from config/environments/<name>/"
	@echo "              Stores state in artifacts/<name>/"
	@echo ""
	@echo "Main Commands:"
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
	@echo "GitOps Commands:"
	@echo "  make push-gitops          - Push gitops/ as OCI artifact (version=git SHA)"
	@echo "  make push-gitops GITOPS_VERSION=v1.0.0 - Push with explicit version"
	@echo "  make tag-gitops TAG=latest - Tag an existing artifact"
	@echo "  make list-artifacts       - List published artifact versions"
	@echo ""
	@echo "Utility Commands:"
	@echo "  make validate     - Validate Terraform configuration"
	@echo "  make fmt          - Format Terraform files"
	@echo "  make show         - Display current Terraform state"
	@echo "  make list         - List all Terraform resources"
	@echo "  make clean        - Remove artifacts and temporary files"
	@echo ""
	@echo "Examples:"
	@echo "  make plan ENV=cc              # Plan Control Center"
	@echo "  make plan-apply ENV=env-prod  # Plan + apply App Environment"
	@echo "  export ENV=cc && make plan    # Set ENV for a session"

# Initialize Terraform
init:
	@echo "Initializing Terraform (ENV=$(ENV))..."
	@mkdir -p $(ARTIFACTS_DIR)
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform init -upgrade -reconfigure \
		-backend-config="$(BACKEND_CONFIG)"

# Validate Terraform configuration
validate:
	@echo "Validating Terraform configuration..."
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform validate

# Format Terraform files
fmt:
	@echo "Formatting Terraform files..."
	@cd $(TF_DIR) && terraform fmt -recursive

# Create Terraform plan and save to artifacts
plan: init
	@echo "Creating Terraform plan (ENV=$(ENV))..."
	@mkdir -p $(ARTIFACTS_DIR)
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform plan -out=../$(PLAN_FILE)
	@echo "Plan saved to $(PLAN_FILE)"

# Apply Terraform changes using saved plan
apply:
	@if [ ! -f "$(PLAN_FILE)" ]; then \
		echo "Error: Plan file not found. Run 'make plan ENV=$(ENV)' first."; \
		exit 1; \
	fi
	@echo "Applying Terraform changes from saved plan (ENV=$(ENV))..."
	@echo "Note: If you get 'stale plan' error, run 'make plan-apply ENV=$(ENV)' instead."
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform apply ../$(PLAN_FILE)

# Plan and apply in one step (prevents stale plan issues)
plan-apply: init
	@echo "Creating and applying Terraform plan (ENV=$(ENV))..."
	@mkdir -p $(ARTIFACTS_DIR)
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform plan -out=../$(PLAN_FILE)
	@echo "Plan created. Applying changes..."
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform apply ../$(PLAN_FILE)

# Apply without plan (direct apply with auto-approve)
apply-direct: init
	@echo "WARNING: Applying changes directly without saved plan..."
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform apply -auto-approve

# Force apply - recreate plan and apply immediately
apply-force: plan-apply
	@echo "Force apply completed."

# Destroy infrastructure
destroy:
	@echo "WARNING: This will destroy all Terraform-managed infrastructure (ENV=$(ENV))!"
	@echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
	@sleep 5
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform destroy -auto-approve

# Fast destroy without refresh (use when resources are already gone)
destroy-fast:
	@echo "WARNING: Fast destroy without refresh - use when resources are already deleted!"
	@echo "Press Ctrl+C to cancel, or wait 3 seconds to continue..."
	@sleep 3
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform destroy -auto-approve -refresh=false

# Clean up artifacts
clean:
	@echo "Cleaning up artifacts..."
	@rm -rf artifacts/
	@echo "Artifacts removed."

# Show current Terraform state
show:
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform show

# List Terraform resources
list:
	@cd $(TF_DIR) && $(LOAD_ENV) && terraform state list

# --------------------------------------------------------------------------
# GitOps OCI Artifact Management
# --------------------------------------------------------------------------

# Push gitops/ directory as OCI artifact
push-gitops:
	@echo "Pushing gitops artifact to oci://$(OCI_REPO):$(GITOPS_VERSION)..."
	@set -a && source $(ENV_FILE) && set +a && \
	flux push artifact oci://$(OCI_REPO):$(GITOPS_VERSION) \
		--path=./$(GITOPS_DIR) \
		--source="$(shell git config --get remote.origin.url)" \
		--revision="$(shell git rev-parse --short HEAD)" \
		--creds="$$OCI_REPO_USERNAME:$$OCI_REPO_PASSWORD"
	@echo "Tagging as latest..."
	@set -a && source $(ENV_FILE) && set +a && \
	flux tag artifact oci://$(OCI_REPO):$(GITOPS_VERSION) --tag=latest \
		--creds="$$OCI_REPO_USERNAME:$$OCI_REPO_PASSWORD"
	@echo "Pushed oci://$(OCI_REPO):$(GITOPS_VERSION) (also tagged latest)"

# Tag an existing artifact with an additional tag
tag-gitops:
	@if [ -z "$(TAG)" ]; then echo "Usage: make tag-gitops TAG=v1.0.0"; exit 1; fi
	@set -a && source $(ENV_FILE) && set +a && \
	flux tag artifact oci://$(OCI_REPO):$(GITOPS_VERSION) --tag=$(TAG) \
		--creds="$$OCI_REPO_USERNAME:$$OCI_REPO_PASSWORD"
	@echo "Tagged oci://$(OCI_REPO):$(GITOPS_VERSION) as $(TAG)"

# List published artifact versions
list-artifacts:
	@echo "Artifacts in oci://$(OCI_REPO):"
	@set -a && source $(ENV_FILE) && set +a && \
	flux list artifacts oci://$(OCI_REPO) \
		--creds="$$OCI_REPO_USERNAME:$$OCI_REPO_PASSWORD"
