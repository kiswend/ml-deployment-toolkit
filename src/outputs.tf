# Output values from the root configuration

output "cluster_name" {
  description = "The name of the cluster"
  value       = local.config.cluster.name
}

output "cluster_vip" {
  description = "The VIP endpoint of the cluster"
  value       = local.config.cluster.vip
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local.kubeconfig_path
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file"
  value       = local.provider_name == "proxmox" && length(module.proxmox) > 0 ? module.proxmox[0].talosconfig_path : null
}

output "flux_installed" {
  description = "Whether FluxCD controllers are installed"
  value       = length(module.flux_bootstrap) > 0 ? module.flux_bootstrap[0].flux_installed : false
}

output "flux_mode" {
  description = "Flux operating mode (none or oci)"
  value       = local.config.cluster.flux.mode
}
