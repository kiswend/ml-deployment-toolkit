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
  description = "Cluster role — determines which gitops path is deployed (cc or env)"
  type        = string

  validation {
    condition     = contains(["cc", "env"], var.cluster_role)
    error_message = "cluster_role must be 'cc' or 'env'."
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

variable "digitalocean_token" {
  description = "DigitalOcean API token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_username" {
  description = "OCI registry username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_password" {
  description = "OCI registry password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "infra_provider" {
  description = "Infrastructure provider name — used to conditionally deploy onprem kustomization"
  type        = string
  default     = ""
}
