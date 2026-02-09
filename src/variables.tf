# Sensitive variables injected via TF_VAR_* environment variables
# Used by flux-config module to create Kubernetes secrets

variable "digitalocean_token" {
  description = "DigitalOcean API token for external-dns"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_username" {
  description = "OCI registry username for Flux OCIRepository"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_password" {
  description = "OCI registry password for Flux OCIRepository"
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
