# Variables for Config Loader Module

variable "config_path" {
  description = "Path to the main configuration file (config/config.yaml)"
  type        = string
  default     = "../config/config.yaml"
}

variable "deployment_templates_path" {
  description = "Path to deployment templates configuration"
  type        = string
  default     = "../config/definitions/deployment-templates.yaml"
}

variable "instance_types_path" {
  description = "Path to instance types configuration"
  type        = string
  default     = "../config/definitions/instance-types.yaml"
}

variable "storage_types_path" {
  description = "Path to storage types configuration"
  type        = string
  default     = "../config/definitions/storage-types.yaml"
}

variable "workload_classes_path" {
  description = "Path to workload classes configuration"
  type        = string
  default     = "../config/definitions/workload-classes.yaml"
}

variable "provider_instance_mapping_path" {
  description = "Path to provider-specific instance type mapping"
  type        = string
  default     = ""
}

variable "provider_storage_mapping_path" {
  description = "Path to provider-specific storage type mapping"
  type        = string
  default     = ""
}
