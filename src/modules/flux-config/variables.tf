variable "flux_namespace" {
  description = "Kubernetes namespace for Flux resources"
  type        = string
  default     = "flux-system"
}

variable "cluster_name" {
  description = "Cluster name for config"
  type        = string
}

variable "cluster_role" {
  description = "Cluster role — determines which gitops paths are deployed (base, cc, or env)"
  type        = string

  validation {
    condition     = contains(["base", "cc", "env"], var.cluster_role)
    error_message = "cluster_role must be 'base', 'cc', or 'env'."
  }
}

variable "cluster_vip" {
  description = "Cluster VIP address (on-prem) or endpoint (cloud)"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Domain name"
  type        = string
}

variable "dns_provider" {
  description = "DNS provider name"
  type        = string
}

variable "alert_email" {
  description = "Alert notification email"
  type        = string
}

variable "lb_ipam_range" {
  description = "Load balancer IPAM range"
  type        = string
}

variable "artifact_url" {
  description = "OCI artifact repository URL (e.g. oci://ghcr.io/mojaloop/ml-gitops)"
  type        = string
}

variable "artifact_version" {
  description = "OCI artifact tag/version (e.g. latest, v1.0.0)"
  type        = string
  default     = "latest"
}

variable "dns_credentials" {
  description = "DNS provider credentials — provider-specific key-value pairs injected into cluster-secrets for Flux postBuild substitution"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "gateway_class_name" {
  description = "GatewayClass name for the shared Gateway (cilium on most providers, gke-specific on GCP)"
  type        = string
  default     = "cilium"
}

variable "oci_repo_username" {
  description = "OCI repo registry username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_repo_password" {
  description = "OCI repo registry password"
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

variable "infra_provider" {
  description = "Infrastructure provider name — used to conditionally deploy vendor kustomization (talos, aws, gcp)"
  type        = string
  default     = ""
}

variable "minio_root_user" {
  description = "MinIO root username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "minio_root_password" {
  description = "MinIO root password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "harbor_admin_password" {
  description = "Harbor admin password"
  type        = string
  default     = ""
  sensitive   = true
}

# --- App Environment Data Layer ---

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

# --- App Environment Data Endpoints (cloud override) ---

variable "mysql_host" {
  description = "MySQL host (cloud: RDS endpoint)"
  type        = string
  default     = ""
}

variable "mysql_port" {
  description = "MySQL port"
  type        = string
  default     = ""
}

variable "kafka_host" {
  description = "Kafka bootstrap server host (cloud: MSK endpoint)"
  type        = string
  default     = ""
}

variable "kafka_port" {
  description = "Kafka bootstrap server port"
  type        = string
  default     = ""
}

variable "mongodb_host" {
  description = "MongoDB host (cloud: DocumentDB endpoint)"
  type        = string
  default     = ""
}

variable "mongodb_port" {
  description = "MongoDB port"
  type        = string
  default     = ""
}

variable "redis_host" {
  description = "Redis host (cloud: ElastiCache endpoint)"
  type        = string
  default     = ""
}

variable "redis_port" {
  description = "Redis port"
  type        = string
  default     = ""
}

# --- App Environment Auth Layer ---

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

