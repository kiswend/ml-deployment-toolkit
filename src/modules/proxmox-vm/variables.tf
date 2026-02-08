# Variables for Proxmox Infrastructure Module
# Talos-only (no standalone VM support)

variable "instances" {
  description = "List of Talos instances to create"
  type = list(object({
    name           = string
    instance_type  = string
    workload_class = string
    storage        = list(any)
    tags           = list(string)
    placement      = any
    resolved_placement = object({
      placement_group = string
    })
  }))
}

variable "provider_mappings" {
  description = "Provider-specific mappings for instance and storage types"
  type = object({
    instance_types = map(any)
    storage_types  = map(any)
  })
}

variable "provider_config_path" {
  description = "Path to Proxmox provider config.yaml"
  type        = string
}

variable "talos_configs" {
  description = "Map of instance name to Talos machine configuration YAML"
  type        = map(string)
  default     = {}
}

variable "workload_classes" {
  description = "Workload classes configuration with VM types and images"
  type        = any
  default     = {}
}
