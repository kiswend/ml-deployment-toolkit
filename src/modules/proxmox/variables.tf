# Variables for Proxmox Cluster Composite Module

variable "instances" {
  description = "List of instances to create (from config-loader)"
  type        = any
}

variable "provider_mappings" {
  description = "Provider-specific mappings for instance and storage types"
  type        = any
}

variable "cluster" {
  description = "Cluster configuration (name, vip, versions, flux)"
  type        = any
}

variable "workload_classes" {
  description = "Workload classes configuration with VM types and images"
  type        = any
  default     = {}
}

variable "patches_path" {
  description = "Path to Talos patches directory"
  type        = string
}

variable "artifacts_path" {
  description = "Path to artifacts directory"
  type        = string
}

variable "provider_config_path" {
  description = "Path to Proxmox provider config.yaml"
  type        = string
}
