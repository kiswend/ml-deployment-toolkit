variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy"
  type        = string
}

variable "talos_version" {
  description = "Talos version to deploy"
  type        = string
}

variable "cluster_endpoint" {
  description = "Cluster API endpoint (IP or hostname)"
  type        = string
  default     = ""
}

variable "lb_ip" {
  description = "Load balancer / VIP address for the cluster endpoint"
  type        = string
  default     = ""
}

variable "talos_endpoints" {
  description = "List of Talos API endpoints (control plane node IPs)"
  type        = list(string)
  default     = []
}

variable "patch_folder" {
  description = "Path to the folder containing Talos configuration patches"
  type        = string
}

variable "artifacts_folder" {
  description = "Path to the folder where artifacts will be stored"
  type        = string
}

variable "additional_patches" {
  description = "List of additional patch contents to apply"
  type        = list(string)
  default     = []
}

variable "generate_per_instance" {
  description = "Generate individual configs for each instance"
  type        = bool
  default     = false
}

variable "instances" {
  description = "List of instances for per-instance config generation"
  type = list(object({
    name             = string
    workload_class   = string
    workload_patches = optional(list(string), [])
  }))
  default = []
}
