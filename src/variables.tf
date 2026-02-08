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
