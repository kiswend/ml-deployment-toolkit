# Environment name — selects config/environments/<env_name>/
variable "env_name" {
  description = "Environment name (maps to config/environments/<env_name>/)"
  type        = string
  default     = "cc"
}

# Sensitive variables injected via TF_VAR_* environment variables
# Used by flux-config module to create Kubernetes secrets

variable "digitalocean_token" {
  description = "DigitalOcean API token for external-dns"
  type        = string
  default     = ""
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
