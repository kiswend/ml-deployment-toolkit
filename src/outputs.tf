# Output values from the root configuration

output "cluster_name" {
  description = "The name of the cluster"
  value       = local.config.cluster.name
}

output "cluster_endpoint" {
  description = "The API endpoint of the cluster"
  value = (
    local.provider_name == "proxmox" ? try(local.config.cluster.vip, null)
    : local.provider_name == "digitalocean" && length(module.digitalocean) > 0 ? module.digitalocean[0].cluster_endpoint
    : local.provider_name == "aws" && length(module.aws) > 0 ? module.aws[0].cluster_endpoint
    : null
  )
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local.kubeconfig_path
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file (on-prem only)"
  value = (
    local.provider_name == "proxmox" && length(module.proxmox) > 0
    ? module.proxmox[0].talosconfig_path
    : null
  )
}

output "flux_installed" {
  description = "Whether FluxCD controllers are installed"
  value       = length(module.flux_bootstrap) > 0 ? module.flux_bootstrap[0].flux_installed : false
}

output "oci_repo_active" {
  description = "Whether Flux OCI reconciliation is active"
  value       = local.oci_active
}
