variable "flux_version" {
  description = "Flux version to install"
  type        = string
  default     = "2.4.0"
}

variable "flux_namespace" {
  description = "Kubernetes namespace for Flux components"
  type        = string
  default     = "flux-system"
}
