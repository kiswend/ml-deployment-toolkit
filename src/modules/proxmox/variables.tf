# Variables for Proxmox Cluster Composite Module

variable "instances" {
  description = "List of instances to create (from config-loader)"
  type        = any
}

variable "cluster" {
  description = "Cluster configuration (name, vip, flux)"
  type        = any
}

variable "workload_classes" {
  description = "Workload classes configuration"
  type        = any
  default     = {}
}

variable "talos_version" {
  description = "Talos version (from workload-classes.yaml)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  type        = string
}

variable "talos_image" {
  description = "Talos image URL and file name (constructed by config-loader)"
  type = object({
    url       = string
    file_name = string
  })
}

variable "label_taint_patches" {
  description = "Dynamic label/taint patches per workload class"
  type        = map(string)
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

variable "oci_proxy_active" {
  description = "Enable container image proxy through Harbor"
  type        = bool
  default     = false
}

variable "oci_proxy_url" {
  description = "Harbor proxy cache URL (no protocol prefix)"
  type        = string
  default     = ""
}

variable "oci_proxy_username" {
  description = "Harbor proxy cache username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_proxy_password" {
  description = "Harbor proxy cache password"
  type        = string
  default     = ""
  sensitive   = true
}
