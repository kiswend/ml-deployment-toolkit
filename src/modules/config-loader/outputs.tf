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
  description = "List of control plane instances (includes mixed-plane)"
  value       = local.control_plane_instances
}

output "worker_instances" {
  description = "List of worker instances"
  value       = local.worker_instances
}

output "workload_classes" {
  description = "Workload classes configuration"
  value       = local.workload_classes.classes
}

output "talos_version" {
  description = "Talos version (from workload-classes.yaml)"
  value       = local.talos_version
}

output "kubernetes_version" {
  description = "Kubernetes version (from workload-classes.yaml)"
  value       = local.kubernetes_version
}

output "talos_image" {
  description = "Talos image URL and file name (constructed from workload-classes.yaml)"
  value = {
    url       = local.talos_image_url
    file_name = local.talos_image_file_name
  }
}

output "label_taint_patches" {
  description = "Dynamic label/taint patches per workload class"
  value       = local.label_taint_patches
}

output "deployment_template" {
  description = "Raw deployment template data (provider-specific structure)"
  value       = local.deployment_template
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
