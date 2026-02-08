# Outputs from Config Loader Module

output "config" {
  description = "Complete deployer configuration (config.yaml)"
  value       = local.config
}

output "provider_name" {
  description = "Infrastructure provider name"
  value       = local.provider_name
}

output "instances" {
  description = "List of all instances with resolved placement"
  value       = local.instances
}

output "control_plane_instances" {
  description = "List of control plane instances"
  value       = local.control_plane_instances
}

output "worker_instances" {
  description = "List of worker instances"
  value       = local.worker_instances
}

output "provider_mappings" {
  description = "Provider-specific mappings for instance and storage types"
  value = {
    instance_types = local.provider_instance_mapping
    storage_types  = local.provider_storage_mapping
  }
}

output "workload_classes" {
  description = "Workload classes configuration with VM types and images"
  value       = local.workload_classes
}

output "cluster" {
  description = "Cluster configuration"
  value       = local.config.cluster
}

output "dns" {
  description = "DNS configuration"
  value       = local.config.dns
}

output "app" {
  description = "Application configuration"
  value       = local.config.app
}

output "artifact_repo" {
  description = "OCI artifact repository configuration"
  value       = try(local.config.cluster.artifact_repo, {})
}

output "paths" {
  description = "Standard paths for artifacts and patches"
  value = {
    artifacts = "../artifacts"
    patches   = "../config/patches/talos"
  }
}
