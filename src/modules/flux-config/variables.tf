variable "flux_namespace" {
  description = "Kubernetes namespace for Flux resources"
  type        = string
  default     = "flux-system"
}

variable "cluster_name" {
  description = "Cluster name for config"
  type        = string
}

variable "cluster_vip" {
  description = "Cluster VIP address"
  type        = string
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

variable "artifact_repo_url" {
  description = "OCI artifact repository URL"
  type        = string
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
