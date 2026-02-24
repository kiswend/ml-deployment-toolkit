# Environment name — selects config/environments/<env_name>/
variable "env_name" {
  description = "Environment name (maps to config/environments/<env_name>/)"
  type        = string
  default     = "cc"
}

# Sensitive variables injected via TF_VAR_* environment variables
# Used by flux-config module to create Kubernetes secrets

variable "dns_credentials" {
  description = "DNS provider credentials — provider-specific key-value pairs (e.g. digitalocean_token, cloudflare_api_token, aws_access_key_id)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "oci_repo_username" {
  description = "OCI repo registry username for Flux OCIRepository"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_repo_password" {
  description = "OCI repo registry password for Flux OCIRepository"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_username" {
  description = "OCI proxy (Harbor) username for container image pull-through cache"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_password" {
  description = "OCI proxy (Harbor) password for container image pull-through cache"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_user" {
  description = "MinIO root username for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_password" {
  description = "MinIO root password for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_admin_password" {
  description = "Harbor admin password for Control Center"
  type        = string
  default     = ""
  sensitive   = true
}

# --- App Environment Data Layer Credentials ---

variable "mysql_root_password" {
  description = "MySQL root password for Percona XtraDB clusters"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_central_ledger_password" {
  description = "MySQL password for central_ledger user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_account_lookup_password" {
  description = "MySQL password for account_lookup user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_oracle_msisdn_password" {
  description = "MySQL password for oracle_msisdn user"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mongodb_root_password" {
  description = "MongoDB admin password for Percona Server MongoDB"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mongodb_app_password" {
  description = "MongoDB mojaloop application user password"
  type        = string
  default     = ""
  sensitive   = true
}

# --- App Environment Auth Layer Credentials ---

variable "keycloak_db_password" {
  description = "Keycloak MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kratos_db_password" {
  description = "Kratos MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keto_db_password" {
  description = "Keto MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mcm_db_password" {
  description = "MCM MySQL user password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_admin_password" {
  description = "Keycloak admin console password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "hubop_oidc_secret" {
  description = "Finance Portal OIDC client secret (hub-operators realm)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "mcm_oidc_client_secret" {
  description = "MCM OIDC client secret (dfsps realm)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "role_assign_svc_secret" {
  description = "Role assignment service account secret"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Backup S3 Credentials (CC MinIO or cloud S3) ---

variable "backup_s3_access_key" {
  description = "S3 access key for backups"
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_secret_key" {
  description = "S3 secret key for backups"
  type        = string
  default     = ""
  sensitive   = true
}

# --- DFSP Onboarding Parameters ---

variable "onboarding_hub_name" {
  description = "Hub participant name in central-ledger for DFSP onboarding"
  type        = string
  default     = "hub"
}

variable "onboarding_funds_in" {
  description = "Initial deposit into DFSP settlement account"
  type        = string
  default     = "100000"
}

variable "onboarding_net_debit_cap" {
  description = "Maximum net debit position for DFSP participants"
  type        = string
  default     = "1000"
}

variable "onboarding_collection_version" {
  description = "TTK test-cases collection version (from mojaloop/testing-toolkit-test-cases)"
  type        = string
  default     = "17.0.4"
}
